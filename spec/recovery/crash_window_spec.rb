require "rails_helper"

# Extension B's ninth child issue — "add Docker restart policies; test crash-window scenarios
# including container kills" — is half policy and half test. The policy shipped in PR 2 and is
# asserted as a declaration in spec/docker_compose_spec.rb; the kills themselves are
# script/verify_recovery.sh's, because nothing inside `bundle exec rspec` can kill the process
# it is running in. This file is the rest of it.
#
# A SIGKILL runs no ensure block, no rescue and no after_commit. So a crash window cannot be
# simulated by stubbing something to raise — that would exercise the very recovery path the
# crash skipped. It is expressed instead as *the durable state a kill leaves behind*, and each
# example asserts what the next process does with that state.
#
# §8 enumerates the windows this design actually has. PR 8 covered three of them
# (pending_enrichment_recovery_spec.rb, worker_crash_lease_spec.rb,
# duplicate_job_execution_spec.rb). The two below are the ones nothing reaches yet, and the
# last group composes all of them into the single restart a container kill really produces.
RSpec.describe "crash windows", type: :integration do
  let(:transport) { fixture_transport }

  before { active_budget_window(now: frozen_time) }

  # ---------------------------------------------------------------------------------------
  # §8: "a SIGKILL still leaves one, and that is the intended crash signal"
  # ---------------------------------------------------------------------------------------
  #
  # IngestionRunner rescues everything it can see and finalizes the run row before re-raising,
  # so `running` with a NULL completed_at is unreachable from any error the process survives —
  # spec/services/github/ingestion_runner_spec.rb covers that path. It is reachable only from a
  # kill, which is why it is the signal, and why nothing tested it.
  describe "a run row abandoned in running" do
    let!(:event_source) { fixture_event_source }

    # The crash: a run opened, and then nothing at all.
    let!(:abandoned) do
      Github::Ingestion::RunRecorder.new(event_source: event_source, clock: -> { frozen_time }).start!
    end

    it "is exactly what a kill leaves: running, with no completion and no counters" do
      expect(abandoned.reload).to have_attributes(status: "running", completed_at: nil)
      expect(IngestionRun::COUNTERS.map { |counter| abandoned.public_send(counter) }).to all(eq(0))
    end

    # The source's scheduling components are written by PollState at the *end* of a run, so a
    # kill costs the source no backoff and the next tick is immediately due. That is the
    # intended behaviour — a crash is not evidence the source is unhealthy.
    it "leaves the source's schedule untouched, so the next tick is immediately due" do
      expect(event_source.reload).to have_attributes(
        cadence_due_at: nil, next_poll_at: nil, last_polled_at: nil, consecutive_failures: 0
      )
    end

    it "never blocks the next poll, because nothing reads it as a claim" do
      result = fixture_runner(transport: transport).call(event_source: event_source)

      expect(result).to be_completed
      expect(PushEvent.count).to eq(4)
      expect(IngestionRun.count).to eq(2)
    end

    # There is no sweeper, and this states plainly that there should not be one: finalizing a
    # row nobody observed completing would fabricate an outcome. The honest posture is to
    # leave the evidence of the crash exactly as the crash left it.
    it "is never resurrected or finalized by anything, which is the honest posture" do
      allow(Github).to receive(:configuration).and_return(configuration_with("GITHUB_MODE" => "fixture"))
      allow(Github::IngestionRunner).to receive(:new).and_call_original
      allow(Github::IngestionRunner).to receive(:new).and_return(fixture_runner(transport: transport))

      before_attributes = abandoned.reload.attributes

      PollEventSourceJob.new.perform_now
      ReconcilePendingEnrichmentsJob.new.perform_now

      expect(abandoned.reload.attributes).to eq(before_attributes)
    end

    # §7's "failures stay spent", across a crash. The killed process may have spent its
    # reservation before dying, and there is no refund path — so the window is charged and the
    # recovery poll spends a second attempt. Conservative in the safe direction: the
    # alternative would be crediting a request GitHub has already counted.
    it "charges the window for the request the dead process may have spent, and never refunds it" do
      Github::BudgetLedger.new.reserve!(:poll, now: frozen_time)

      fixture_runner(transport: transport).call(event_source: event_source)

      expect(current_budget.poll_used).to eq(2)
    end
  end

  # ---------------------------------------------------------------------------------------
  # The window §8's per-envelope transaction exists for
  # ---------------------------------------------------------------------------------------
  #
  # ADR 0005: "Transactions are per envelope, not per page. PostgreSQL aborts an entire
  # transaction on any failed statement, so a page-wide transaction would let one malformed
  # envelope discard the events already reported as persisted beside it."
  #
  # Every existing duplicate test replays a *complete* page, which exercises the snapshot
  # rather than the boundary. A prefix is the shape a kill actually produces, and it is the
  # only thing that can tell a per-envelope transaction from a per-page one.
  describe "a page interrupted between two envelopes" do
    let(:page) { corpus_page("page-1.json") }
    let(:writer) { Github::Ingestion::PageWriter.new(clock: -> { frozen_time }) }

    # Envelopes 0..2 are the three well-formed push events at the head of the page. The kill
    # lands after them and before everything else.
    def write_prefix(count = 3)
      writer.write(page.first(count), run_id: SecureRandom.uuid)
    end

    def replay_whole_page
      Github::Ingestion::PageWriter.new(clock: -> { frozen_time + 60 })
                                   .write(page, run_id: SecureRandom.uuid)
    end

    it "commits a prefix of the page rather than all of it or none of it" do
      write_prefix

      expect(PushEvent.count).to eq(3)
      expect(GithubActor.count).to eq(2)
      expect(GithubRepository.count).to eq(2)
      expect(QuarantinedEvent.count).to eq(0)
    end

    it "persists exactly the remainder on replay, with the prefix absorbed as duplicates" do
      write_prefix
      tally = replay_whole_page

      expect(tally.events_created).to eq(1)
      expect(tally.duplicates_skipped).to eq(3)
      expect(PushEvent.count).to eq(4)
      expect(GithubActor.count).to eq(3)
      expect(GithubRepository.count).to eq(3)
    end

    # ADR 0005's fourth mechanism, holding across a crash boundary rather than across a plain
    # replay: the duplicated envelopes produce no RETURNING row, so the reactivation they
    # would otherwise trigger never runs.
    it "reactivates nothing the prefix already recorded" do
      write_prefix
      GithubActor.where(github_id: IngestionHelpers::ACTOR_GITHUB_ID)
                 .update_all(enrichment_status: "skipped_budget", skipped_at: frozen_time)

      replay_whole_page

      expect(GithubActor.find_by(github_id: IngestionHelpers::ACTOR_GITHUB_ID))
        .to have_attributes(enrichment_status: "skipped_budget", skipped_at: frozen_time)
    end

    # The other half of the same rule, so the first is not passing merely because nothing
    # reactivates anything: a genuinely new event for the same entity does.
    it "still reactivates that entity for an event the crash had not yet seen" do
      write_prefix
      GithubActor.where(github_id: IngestionHelpers::ACTOR_GITHUB_ID)
                 .update_all(enrichment_status: "skipped_budget", skipped_at: frozen_time)

      writer.write([ well_formed_envelope("id" => "58000009999") ], run_id: SecureRandom.uuid)

      expect(GithubActor.find_by(github_id: IngestionHelpers::ACTOR_GITHUB_ID))
        .to have_attributes(enrichment_status: "pending", skipped_at: nil)
    end

    # PageWriter#quarantine is deliberately one statement outside every transaction. A crash
    # mid-page must therefore keep the quarantine rows it had already written, and the replay
    # must count the second observation rather than create a second row.
    it "keeps quarantine rows written before the crash, and counts the replay as a recurrence" do
      writer.write(page.first(5), run_id: SecureRandom.uuid)

      expect(QuarantinedEvent.count).to eq(1)
      expect(QuarantinedEvent.sole.occurrence_count).to eq(1)

      replay_whole_page

      expect(QuarantinedEvent.count).to eq(3)
      expect(QuarantinedEvent.order(:id).first.occurrence_count).to eq(2)
    end
  end

  # ---------------------------------------------------------------------------------------
  # The order a crash can interrupt finish() in
  # ---------------------------------------------------------------------------------------
  #
  # IngestionRunner#finish writes poll state before finalizing the run row. The ordering is
  # commented in the source as being about the completion *log line*, but it also decides
  # which of two states a kill between the two writes can leave — and only one of them is
  # safe. Observed through the statements actually issued, so nothing is stubbed and the
  # assertion is about the real sequence.
  describe "the order a crash can interrupt a run's completion in" do
    it "writes the source's backoff before finalizing the run, never the reverse" do
      statements = []

      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        next if payload[:name] == "SCHEMA" || payload[:cached]

        statements << payload[:sql]
      end

      begin
        fixture_runner(transport: transport).call(event_source: fixture_event_source)
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      source_update = statements.index { |sql| sql.match?(/\AUPDATE\s+"event_sources"/i) }
      run_update = statements.index { |sql| sql.match?(/\AUPDATE\s+"ingestion_runs"/i) }

      expect(source_update).not_to be_nil
      expect(run_update).not_to be_nil
      expect(source_update).to be < run_update
    end

    # Why the order above is the safe one. A crash in that window leaves a source that has
    # backed off and a run row still marked running — which is a visible, self-correcting
    # state. The reverse would leave a finalized run and a source with no cadence written, so
    # the next tick would be immediately due and would spend another request into the same
    # crash: a hot loop, and §10's "do not crash-loop the poller" forbids exactly that.
    it "means a crash in that window can never leave the source immediately due again" do
      result = fixture_runner(transport: transport).call(event_source: fixture_event_source)

      expect(result).to be_completed
      expect(EventSource.sole.cadence_due_at).to be_present
      expect(EventSource.sole.next_poll_at).to be_present
    end
  end

  # ---------------------------------------------------------------------------------------
  # The whole thing at once
  # ---------------------------------------------------------------------------------------
  #
  # Each crash signature is covered on its own: a held source lock whose session dies
  # (advisory_lock_session_death_spec.rb), an abandoned entity lease (worker_crash_lease_spec.rb),
  # a lost enqueue (pending_enrichment_recovery_spec.rb). A container kill produces all three
  # in one instant, and nothing composes them — which matters, because the interesting
  # question is not whether each recovers but whether they recover *together*, with no
  # operator step and no ordering between them.
  #
  # This is as close as RSpec gets to §15 step 8. The transcript in docs/evidence/ is the rest.
  describe "the whole container-kill cycle, without the container" do
    let(:source_namespace) { Github::AdvisoryLock::SOURCE_LOCK_NAMESPACE }
    let(:claim) { Github::Enrichment::Claim.new(configuration: Github.configuration) }
    let(:actor_type) { Github::Enrichment::EntityType.fetch(:actor) }
    let!(:event_source) { fixture_event_source }

    # Ingested at Time.current rather than at frozen_time, for the reason
    # pending_enrichment_recovery_spec.rb states: Solid Queue constructs
    # ReconcilePendingEnrichmentsJob, so there is no clock to inject into it and its sweep
    # measures §10's eligibility window against the wall clock. Entities stamped in 2026-07-29
    # would be outside that window today, and the reconciler would correctly find nothing —
    # which would make this example pass for a reason that has nothing to do with recovery.
    let(:crashed_at) { Time.current }

    before { active_budget_window(now: crashed_at) }

    # Everything a worker container was holding at the instant it was killed.
    def crash!
      fixture_runner(transport: transport, now: crashed_at).call(event_source: event_source)

      claim.acquire(actor_type, pool: :pending, now: crashed_at)    # a lease with no worker
      clear_enqueued_jobs                                           # the lost enqueue
      acquire_in_other_session(source_namespace,                    # the dead poller's lock
                               Github::AdvisoryLock.key_for(event_source.id))
      terminate_second_session!                                     # the kill
      wait_for_advisory_lock_release(source_namespace, Github::AdvisoryLock.key_for(event_source.id))
    end

    # The restart, running only the two recurring tasks a real worker runs, at a clock past
    # the abandoned lease's expiry — so the entity the dead worker was holding is reachable
    # again by arithmetic alone, with no cleanup step.
    def restart!
      allow(Github).to receive(:configuration).and_return(configuration_with("GITHUB_MODE" => "fixture"))
      allow(Github::EnrichmentRunner).to receive(:new).and_call_original
      allow(Github::EnrichmentRunner).to receive(:new)
        .and_return(fixture_enrichment_runner(transport: transport,
                                              now: crashed_at + claim.lease_seconds + 1))

      6.times do
        ReconcilePendingEnrichmentsJob.perform_now
        perform_enqueued_jobs
      end
    end

    it "converges on the state the uncrashed run would have reached" do
      crash!
      restart!

      expect(PushEvent.count).to eq(4)
      expect(GithubActor.find_by(github_id: IngestionHelpers::ACTOR_GITHUB_ID))
        .to have_attributes(enrichment_status: "complete", name: "The Octocat")
      expect(GithubRepository.find_by(github_id: IngestionHelpers::REPOSITORY_GITHUB_ID).enrichment_status)
        .to eq("complete")
    end

    it "needs no operator step, no cleanup job and no sweeper to get there" do
      crash!
      restart!

      expect(advisory_lock_holders(source_namespace, Github::AdvisoryLock.key_for(event_source.id)))
        .to be_empty
      expect(Github::LockOrder.held_keys).to be_empty
    end

    # The crash itself is not evidence of a fault, so nothing that survived it should carry a
    # penalty for it.
    it "charges the crashed entity no attempt and the source no failure" do
      crash!
      restart!

      expect(GithubActor.find_by(github_id: IngestionHelpers::ACTOR_GITHUB_ID).enrichment_attempts).to eq(0)
      expect(event_source.reload.consecutive_failures).to eq(0)
    end
  end
end
