require "rails_helper"

# §9's fourth multi-poller protection — "unique event constraints as final duplicate
# protection" — under genuine concurrency.
#
# Every existing duplicate test (page_writer_spec.rb, ingestion_runner_spec.rb) replays a page
# sequentially in one session, which exercises the transaction's own snapshot rather than the
# unique index. The interesting case is the one the index exists for: another poller committed
# the row microseconds ago, from a session this one has never seen, and the write has to absorb
# it under READ COMMITTED.
#
# This is the second file in the suite to turn transactional fixtures off, and the reason is
# the same one spec/services/github/budget_ledger_durability_spec.rb gives: the property under
# test is *what one session can see of another's commit*, and a fixture transaction hides
# exactly that. It also cannot be worked around with an `around` hook — an `around`'s ensure
# still runs inside the fixture transaction, so its cleanup would be rolled back with
# everything else and the committed rows would survive into the next example.
#
# The price is that this file owns its own cleanup, and under config.order = :random that
# cleanup is load-bearing: a leftover row would break unrelated files' create_actor with a
# uniqueness violation, and a stranded lock_timeout would give every later example on this
# connection a 250ms deadline it never asked for. Hence around + ensure rather than an after
# hook — it has to run even when the example raises — and deletion in reverse insertion order,
# which the schema requires: push_events carries real foreign keys to github_actors.github_id
# and github_repositories.github_id.
RSpec.describe "a page racing another poller's commit", type: :integration do
  self.use_transactional_tests = false

  ACTOR_ID = IngestionHelpers::ACTOR_GITHUB_ID
  REPOSITORY_ID = IngestionHelpers::REPOSITORY_GITHUB_ID
  OTHER_ACTOR_ID = 9_100_001
  OTHER_REPOSITORY_ID = 9_200_001
  EVENT_ID = "58000000001".freeze
  OTHER_EVENT_ID = "58000009001".freeze

  let(:writer) { Github::Ingestion::PageWriter.new(clock: -> { frozen_time }) }
  let(:stamp) { frozen_time.iso8601 }

  around do |example|
    example.run
  ensure
    # The second session may still be inside its FOR UPDATE transaction if an example failed
    # before its own rollback ran, and nothing can delete the row it holds until it is out.
    begin
      second_session.exec("ROLLBACK")
    rescue StandardError
      nil
    end
    close_second_session

    connection = ActiveRecord::Base.connection
    # Session-level, not SET LOCAL: the only transaction it could have been local to belongs
    # to PageWriter. With no fixture transaction to revert it, this RESET is the only thing
    # that stops a 250ms lock timeout riding the pooled connection into the rest of the run.
    connection.execute("RESET lock_timeout")
    # The event-native observations first: they carry a real foreign key to the
    # push_events rows deleted next.
    connection.execute(
      "DELETE FROM enrichment_observations WHERE push_event_id IN " \
      "(SELECT id FROM push_events WHERE github_event_id IN ('#{EVENT_ID}', '#{OTHER_EVENT_ID}'))"
    )
    connection.execute(
      "DELETE FROM push_events WHERE github_event_id IN ('#{EVENT_ID}', '#{OTHER_EVENT_ID}')"
    )
    connection.execute("DELETE FROM github_actors WHERE github_id IN (#{ACTOR_ID}, #{OTHER_ACTOR_ID})")
    connection.execute(
      "DELETE FROM github_repositories WHERE github_id IN (#{REPOSITORY_ID}, #{OTHER_REPOSITORY_ID})"
    )
  end

  # The other poller: a genuinely separate PostgreSQL session, committing before this one
  # looks. Raw SQL rather than Active Record, because the pooled connection is inside the
  # example's fixture transaction and anything written through it would be invisible to the
  # index this file is about.
  def commit_actor!(status: "pending", next_retry_at: nil, last_error: nil)
    second_session.exec_params(<<~SQL, [ ACTOR_ID, "octocat", status, stamp, next_retry_at, last_error ])
      INSERT INTO github_actors
        (github_id, login, display_login, api_url, enrichment_status, enrichment_attempts,
         last_seen_at, first_seen_at, created_at, updated_at, next_retry_at, last_error)
      VALUES ($1, $2, $2, 'https://api.github.com/users/octocat', $3, 0, $4, $4, $4, $4, $5, $6)
    SQL
  end

  def commit_repository!
    second_session.exec_params(<<~SQL, [ REPOSITORY_ID, "octocat/Hello-World", "Hello-World", stamp ])
      INSERT INTO github_repositories
        (github_id, full_name, name, api_url, enrichment_status, enrichment_attempts,
         last_seen_at, first_seen_at, created_at, updated_at)
      VALUES ($1, $2, $3, 'https://api.github.com/repos/octocat/Hello-World', 'pending', 0, $4, $4, $4, $4)
    SQL
  end

  def commit_push_event!
    second_session.exec_params(<<~SQL, [ EVENT_ID, REPOSITORY_ID, ACTOR_ID, sha_40, sha_64, stamp ])
      INSERT INTO push_events
        (github_event_id, github_push_id, github_repository_id, github_actor_id,
         ref, head_sha, before_sha, occurred_at, raw_payload, created_at, updated_at)
      VALUES ($1, 27500000001, $2, $3, 'refs/heads/main', $4, $5, $6, '{"type":"PushEvent"}', $6, $6)
    SQL
  end

  describe "an event the other poller committed first" do
    before do
      commit_actor!
      commit_repository!
      commit_push_event!
    end

    # ON CONFLICT (github_event_id) DO NOTHING RETURNING id, against a row this session never
    # inserted and cannot roll back. §9's last line of defence, doing its job.
    it "absorbs it as a duplicate rather than raising or double-writing" do
      tally = writer.write([ well_formed_envelope ], run_id: SecureRandom.uuid)

      expect(tally.duplicates_skipped).to eq(1)
      expect(tally.events_created).to eq(0)
      expect(PushEvent.where(github_event_id: EVENT_ID).count).to eq(1)
    end

    # The RETURNING gate holding under concurrency. Without it two pollers racing the same
    # page would each register activity for the same event, and last_seen_at would report
    # traffic that never happened.
    it "registers no activity for the loser" do
      writer.write([ well_formed_envelope ], run_id: SecureRandom.uuid)

      expect(GithubActor.find_by(github_id: ACTOR_ID).last_seen_at).to eq(frozen_time)
      expect(GithubActor.find_by(github_id: ACTOR_ID).latest_event_at).to be_nil
    end

    # The observation ledger rides the same RETURNING gate: a duplicate that registered
    # no activity appended no event-native evidence either.
    it "appends no observation for the loser" do
      writer.write([ well_formed_envelope ], run_id: SecureRandom.uuid)

      expect(EnrichmentObservation.where(source: "event")).to be_empty
    end
  end

  describe "a retryable entity whose event another poller committed first" do
    before do
      commit_actor!(status: "retryable_failure", next_retry_at: stamp,
                    last_error: "GitHub unavailable")
      commit_repository!
      commit_push_event!
    end

    it "preserves its failure state when this poller loses the event-insert race" do
      writer.write([ well_formed_envelope ], run_id: SecureRandom.uuid)

      expect(GithubActor.find_by(github_id: ACTOR_ID))
        .to have_attributes(enrichment_status: "retryable_failure",
                            next_retry_at: frozen_time, last_error: "GitHub unavailable")
    end
  end

  # PageWriter#persist upserts the actor before the repository, always, with the comment "so
  # two concurrent pages touching the same pair cannot deadlock on the two entity rows".
  # Nothing asserted it. Two pages taking the rows in the same order cannot form a cycle; two
  # taking them in opposite orders can, and the symptom would be an intermittent
  # ActiveRecord::Deadlocked in production and nowhere else.
  #
  # Asserted on the statements actually issued, and deliberately not by holding one row and
  # watching the other fail to appear: both upserts share one per-envelope transaction, so a
  # blocked second upsert rolls the first one back too and the observable is identical
  # whichever order they run in. Statement order is the only thing that distinguishes them —
  # verified by swapping the two lines in PageWriter#persist, which fails this example and
  # nothing else in the suite.
  describe "the order the two entity rows are taken in" do
    def capture_sql
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        next if payload[:name] == "SCHEMA" || payload[:cached]

        statements << payload[:sql]
      end

      yield
      statements
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "upserts the actor before the repository, always" do
      statements = capture_sql { writer.write([ well_formed_envelope ], run_id: SecureRandom.uuid) }

      actor_at = statements.index { |sql| sql.match?(/INSERT INTO "github_actors"/i) }
      repository_at = statements.index { |sql| sql.match?(/INSERT INTO "github_repositories"/i) }

      expect(actor_at).not_to be_nil
      expect(repository_at).not_to be_nil
      expect(actor_at).to be < repository_at
    end
  end

  # What a contended entity row actually costs, which is a different question from the order
  # the rows are taken in.
  describe "when another session holds the actor row" do
    before do
      commit_actor!
      second_session.exec("BEGIN")
      second_session.exec_params("SELECT 1 FROM github_actors WHERE github_id = $1 FOR UPDATE", [ ACTOR_ID ])

      # Converts "would block forever" into a typed, bounded failure. Without it this example
      # hangs the container rather than failing, because PostgreSQL reads the default
      # lock_timeout of 0 as "no timeout".
      ActiveRecord::Base.connection.execute("SET lock_timeout = '250ms'")
    end

    # The lock wait surfaces as an ActiveRecord::LockWaitTimeout, which is not one of
    # PageWriter::FATAL_ERRORS — so it is classified as a failed envelope rather than
    # terminating the batch, and §16's "malformed data does not terminate the batch" extends
    # to a contended one.
    it "fails that envelope rather than raising out of the page" do
      tally = nil

      expect { tally = writer.write([ well_formed_envelope ], run_id: SecureRandom.uuid) }
        .not_to raise_error
      expect(tally.events_failed).to eq(1)
      expect(tally.events_created).to eq(0)
    end

    # ADR 0005's per-envelope transaction, seen from the failure side: the envelope leaves no
    # half-written entity pair behind — and no orphan observation — because the repository
    # upsert and the observation appends were inside the same transaction the timeout
    # rolled back.
    it "leaves no partial pair behind" do
      writer.write([ well_formed_envelope ], run_id: SecureRandom.uuid)

      expect(GithubRepository.where(github_id: REPOSITORY_ID)).to be_empty
      expect(PushEvent.where(github_event_id: EVENT_ID)).to be_empty
      expect(EnrichmentObservation.where(source: "event")).to be_empty
    end

    # ADR 0005's per-envelope transaction, against a real contended row rather than the
    # synthetic bad value page_writer_spec.rb uses: one envelope's failure does not discard
    # the envelope beside it.
    it "still persists the envelopes that do not touch the held row" do
      other = well_formed_envelope(
        "id" => "58000009001",
        "actor" => { "id" => 9_100_001, "login" => "other", "display_login" => "other",
                     "url" => "https://api.github.com/users/other" },
        "repo" => { "id" => 9_200_001, "name" => "other/repo",
                    "url" => "https://api.github.com/repos/other/repo" },
        "payload" => { "repository_id" => 9_200_001 }
      )

      tally = writer.write([ well_formed_envelope, other ], run_id: SecureRandom.uuid)

      expect(tally.events_failed).to eq(1)
      expect(tally.events_created).to eq(1)
      expect(PushEvent.where(github_event_id: "58000009001")).to exist
    end
  end
end
