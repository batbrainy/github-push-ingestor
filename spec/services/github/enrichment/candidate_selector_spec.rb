require "rails_helper"

RSpec.describe Github::Enrichment::CandidateSelector do
  subject(:selector) { described_class.new(configuration: configuration) }

  let(:configuration) { configuration_with }
  let(:now) { frozen_time }
  let(:actor_type) { Github::Enrichment::EntityType.fetch(:actor) }
  let(:repository_type) { Github::Enrichment::EntityType.fetch(:repository) }

  def pending_actor(github_id:, last_seen_at: now - 60, **overrides)
    create_actor(github_id: github_id, last_seen_at: last_seen_at, **overrides)
  end

  def next_pending(entity_type = actor_type)
    selector.scope(entity_type, pool: :pending, now: now).first
  end

  def next_refresh(entity_type = actor_type)
    selector.scope(entity_type, pool: :refresh, now: now).first
  end

  describe "the pending pool" do
    it "enriches oldest-created first, so every durable backlog row advances toward service" do
      oldest = pending_actor(github_id: 1, created_at: now - 600)
      pending_actor(github_id: 2, created_at: now - 10)

      expect(next_pending).to eq(oldest)
    end

    # PageWriter creates many stubs in one page with one timestamp. The ascending id tie
    # break preserves insertion order rather than letting PostgreSQL choose a plan-dependent
    # winner on every reconciliation tick.
    it "breaks a created-at tie by ascending id" do
      first = pending_actor(github_id: 1, created_at: now - 60)
      pending_actor(github_id: 2, created_at: now - 60)

      expect(next_pending).to eq(first)
    end

    it "offers a retryable failure alongside a pending row, which is what the index predicate says" do
      retryable = pending_actor(github_id: 1, enrichment_status: "retryable_failure")

      expect(next_pending).to eq(retryable)
    end

    it "excludes a candidate whose retry has not come due" do
      pending_actor(github_id: 1, next_retry_at: now + 60)

      expect(next_pending).to be_nil
    end

    it "offers a candidate again the instant its retry is due" do
      due = pending_actor(github_id: 1, next_retry_at: now)

      expect(next_pending).to eq(due)
    end

    it "keeps an old candidate claimable until it is eventually enriched" do
      old = pending_actor(github_id: 1, last_seen_at: now - 100_000,
                          created_at: now - 100_000)

      expect(next_pending).to eq(old)
    end

    it "excludes a terminal status, which no amount of budget would help" do
      pending_actor(github_id: 1, enrichment_status: "permanent_failure")

      expect(next_pending).to be_nil
    end

    # A stub can be created with a NULL last_seen_at: PageWriter upserts the stub, the
    # push_events insert returns nil on a duplicate, and the transaction still commits.
    # created_at is total and immutable, so the durable FIFO can still order this work.
    it "keeps a stub with no last_seen_at claimable regardless of age" do
      stub = create_actor(github_id: 1, last_seen_at: nil, created_at: now - 100_000)

      expect(next_pending).to eq(stub)
    end

    it "orders solely by durable insertion time, not later activity" do
      oldest = pending_actor(github_id: 1, created_at: now - 600, last_seen_at: now - 10)
      pending_actor(github_id: 2, created_at: now - 300, last_seen_at: now - 200)

      expect(next_pending).to eq(oldest)
    end

    it "keeps the two classes apart, so a repository backlog never appears as actor work" do
      create_repository(github_id: 1, last_seen_at: now - 60)

      expect(next_pending(actor_type)).to be_nil
      expect(next_pending(repository_type)).not_to be_nil
    end
  end

  describe "the refresh pool (plan §10's freshness cache)" do
    def complete_actor(github_id:, fetched_at:, **overrides)
      create_actor(github_id: github_id, enrichment_status: "complete", fetched_at: fetched_at,
                   last_seen_at: now - 60, **overrides)
    end

    it "treats a record inside its TTL as fresh and offers nothing" do
      complete_actor(github_id: 1, fetched_at: now - 86_399)

      expect(next_refresh).to be_nil
    end

    it "offers a refresh once the TTL has passed" do
      stale = complete_actor(github_id: 1, fetched_at: now - 86_400)

      expect(next_refresh).to eq(stale)
    end

    # Oldest-fetched first is the rule that terminates: a monotone refresh queue cannot
    # starve a complete row behind a hotter neighbour.
    it "refreshes the most stale record first, so no complete row can be starved" do
      complete_actor(github_id: 1, fetched_at: now - 90_000)
      oldest = complete_actor(github_id: 2, fetched_at: now - 200_000)

      expect(next_refresh).to eq(oldest)
    end

    it "defers a refresh whose last attempt backed off" do
      complete_actor(github_id: 1, fetched_at: now - 90_000, next_retry_at: now + 60)

      expect(next_refresh).to be_nil
    end

    it "reads each class's own TTL" do
      short = described_class.new(configuration: configuration_with(REPOSITORY_REFRESH_TTL_SECONDS: "60"))
      create_repository(github_id: 1, enrichment_status: "complete", fetched_at: now - 120,
                        last_seen_at: now - 60)

      expect(short.scope(repository_type, pool: :refresh, now: now).first).not_to be_nil
      expect(next_refresh(repository_type)).to be_nil
    end

    it "offers a refresh regardless of how long ago the entity was referenced" do
      stale = complete_actor(github_id: 1, fetched_at: now - 90_000, last_seen_at: now - 100_000)

      expect(next_refresh).to eq(stale)
    end
  end

  describe "#pending_available?" do
    it "answers true for old durable work rather than treating age as ineligibility" do
      pending_actor(github_id: 1, last_seen_at: now - 100_000, created_at: now - 100_000)

      expect(GithubActor.count).to eq(1)
      expect(selector.pending_available?(actor_type, now: now)).to be(true)
    end

    it "answers true while one eligible candidate remains" do
      pending_actor(github_id: 1)

      expect(selector.pending_available?(actor_type, now: now)).to be(true)
    end

    # §10's prioritization ladder ranks refreshing stale enrichment below enriching
    # never-seen entities *globally*. Counting refreshes here would let one class decline
    # to lend its idle capacity because the other had a refresh waiting, inverting it.
    it "reports pending availability without counting refreshes, which rank below it" do
      create_actor(github_id: 1, enrichment_status: "complete", fetched_at: now - 90_000)

      expect(selector.pending_available?(actor_type, now: now)).to be(false)
    end
  end

  describe "#pending_backlog?" do
    it "sees never-enriched work even while its retry is deferred" do
      pending_actor(github_id: 1, enrichment_status: "retryable_failure",
                    next_retry_at: now + 3600)

      expect(selector.pending_available?(actor_type, now: now)).to be(false)
      expect(selector.pending_backlog?(actor_type)).to be(true)
    end

    it "does not count complete or permanently failed rows as never-enriched backlog" do
      create_actor(github_id: 1, enrichment_status: "complete", fetched_at: now)
      create_actor(github_id: 2, enrichment_status: "permanent_failure")

      expect(selector.pending_backlog?(actor_type)).to be(false)
    end

    it "keeps entity classes independent" do
      create_repository(github_id: 1)

      expect(selector.pending_backlog?(actor_type)).to be(false)
      expect(selector.pending_backlog?(repository_type)).to be(true)
    end
  end

  describe "#claimable?" do
    it "is true while a pending candidate is eligible" do
      pending_actor(github_id: 1)

      expect(selector.claimable?(actor_type, now: now)).to be(true)
    end

    # The half that was missing, and the reason a fully enriched backlog reported "due
    # now": a stale refresh is work, so a class holding one is not idle.
    it "is true while only a TTL-stale refresh is waiting" do
      create_actor(github_id: 1, enrichment_status: "complete", fetched_at: now - 90_000)

      expect(selector.claimable?(actor_type, now: now)).to be(true)
    end

    it "is false when every record is enriched and still fresh" do
      create_actor(github_id: 1, enrichment_status: "complete", fetched_at: now)

      expect(selector.claimable?(actor_type, now: now)).to be(false)
    end

    it "is false when the only candidate is deferred" do
      pending_actor(github_id: 1, next_retry_at: now + 60)

      expect(selector.claimable?(actor_type, now: now)).to be(false)
    end
  end

  describe "#earliest_pending_at" do
    it "names the soonest instant at which a deferred candidate becomes claimable" do
      pending_actor(github_id: 1, next_retry_at: now + 300)
      pending_actor(github_id: 2, next_retry_at: now + 60)

      expect(selector.earliest_pending_at(actor_type, now: now)).to eq(now + 60)
    end

    it "is nil when nothing is deferred, because the answer is not a pending instant" do
      pending_actor(github_id: 1)

      expect(selector.earliest_pending_at(actor_type, now: now)).to be_nil
    end

    it "names the retry instant even for a very old candidate" do
      pending_actor(github_id: 1, next_retry_at: now + 60,
                    last_seen_at: now - 100_000, created_at: now - 100_000)

      expect(selector.earliest_pending_at(actor_type, now: now)).to eq(now + 60)
    end
  end

  describe "#earliest_refresh_at" do
    def complete_actor(github_id:, fetched_at:, **overrides)
      create_actor(github_id: github_id, enrichment_status: "complete", fetched_at: fetched_at, **overrides)
    end

    it "names the instant the freshness cache lets go" do
      complete_actor(github_id: 1, fetched_at: now)

      expect(selector.earliest_refresh_at(actor_type, now: now)).to eq(now + 86_400)
    end

    it "names the earliest across every enriched record" do
      complete_actor(github_id: 1, fetched_at: now)
      complete_actor(github_id: 2, fetched_at: now - 600)

      expect(selector.earliest_refresh_at(actor_type, now: now)).to eq(now + 85_800)
    end

    # A complete row can carry a retry instant: a retryable failure on a refresh keeps the
    # status (a network blip must not drop coverage) and backs the row off. The next legal
    # fetch is the later of the two.
    it "defers to a failed refresh's backoff when it outlasts the TTL" do
      complete_actor(github_id: 1, fetched_at: now - 90_000, next_retry_at: now + 300)

      expect(selector.earliest_refresh_at(actor_type, now: now)).to eq(now + 300)
    end

    it "ignores a retry instant that has already passed, which no longer defers anything" do
      complete_actor(github_id: 1, fetched_at: now, next_retry_at: now - 300)

      expect(selector.earliest_refresh_at(actor_type, now: now)).to eq(now + 86_400)
    end

    # The minimum is taken over the whole expression rather than over fetched_at alone,
    # because the oldest document may be the one carrying the longest backoff.
    it "takes the minimum over both columns together, not over the oldest fetch" do
      complete_actor(github_id: 1, fetched_at: now - 86_000, next_retry_at: now + 9_000)
      complete_actor(github_id: 2, fetched_at: now - 85_000)

      expect(selector.earliest_refresh_at(actor_type, now: now)).to eq(now + 1_400)
    end

    it "reads each class's own TTL" do
      short = described_class.new(configuration: configuration_with(REPOSITORY_REFRESH_TTL_SECONDS: "60"))
      create_repository(github_id: 1, enrichment_status: "complete", fetched_at: now)

      expect(short.earliest_refresh_at(repository_type, now: now)).to eq(now + 60)
    end

    it "is nil when nothing has been enriched, because there is no refresh to name" do
      pending_actor(github_id: 1)

      expect(selector.earliest_refresh_at(actor_type, now: now)).to be_nil
    end
  end

  describe "#earliest_claimable_at" do
    it "keeps refresh timing subordinate to the deferred first-time backlog" do
      pending_actor(github_id: 1, next_retry_at: now + 300)
      create_actor(github_id: 2, enrichment_status: "complete", fetched_at: now - 86_340)

      expect(selector.earliest_claimable_at(actor_type, now: now)).to eq(now + 300)
    end

    it "falls back to the refresh pool when nothing is pending at all" do
      create_actor(github_id: 1, enrichment_status: "complete", fetched_at: now)

      expect(selector.earliest_claimable_at(actor_type, now: now)).to eq(now + 86_400)
    end

    it "is nil for a class with nothing at all in either pool" do
      expect(selector.earliest_claimable_at(actor_type, now: now)).to be_nil
    end
  end

  it "refuses an unknown pool rather than silently selecting nothing" do
    expect { selector.scope(actor_type, pool: :everything, now: now) }
      .to raise_error(ArgumentError, /everything/)
  end
end
