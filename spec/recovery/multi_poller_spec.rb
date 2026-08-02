require "rails_helper"

# §9's "Multiple poller containers", at the depth PR 11 owes it. PR 8 established the
# baseline — spec/recovery/source_contention_spec.rb covers a tick against a source another
# process holds *for the whole tick*, where the loser never gets in at all.
#
# The scenario that decides whether the design is correct is the other one: both pollers
# read the row before mutual exclusion existed, both concluded a poll was due, and the
# loser acquires the lock *after* the winner has finished and committed. ADR 0006 rejected
# checking the cadence before taking the lock for exactly this reason — "two processes would
# both read a stale cadence_due_at, both decide they were due, serialize on the lock, and
# poll back to back" — and the defence is one `event_source.reload` inside
# IngestionRunner#call. Nothing tested it.
#
# Every "second poller" here is either a genuinely separate PostgreSQL session
# (spec/support/advisory_lock_helpers.rb) or a second Ruby object over one committed row.
# Never a thread: session advisory locks are re-entrant within a session and the pinned pool
# connection is shared, so a thread-based version of any example below would pass even
# against an empty Github::RequestGate.hold.
RSpec.describe "multiple pollers", type: :integration do
  let(:source_namespace) { Github::AdvisoryLock::SOURCE_LOCK_NAMESPACE }
  let(:gate_namespace) { Github::AdvisoryLock::REQUEST_GATE_NAMESPACE }
  let(:gate_key) { Github::AdvisoryLock::REQUEST_GATE_KEY }

  before { active_budget_window(now: frozen_time) }

  # ---------------------------------------------------------------------------------------
  # §9, bullet 1 — the session advisory lock per source
  # ---------------------------------------------------------------------------------------
  describe "two pollers that both decided the source was due" do
    # Two transports, because Github::Transports::Fixture keeps its scripted-response cursor
    # on the instance — one per simulated process is what makes them independent.
    let(:transport_a) { fixture_transport }
    let(:transport_b) { fixture_transport }

    # Poller B's read of the row, taken before poller A ran and therefore before any mutual
    # exclusion existed. This is the whole scenario in one line.
    let!(:stale) { fixture_event_source }

    def poll_a(force: false)
      fixture_runner(transport: transport_a).call(event_source: fixture_event_source, force: force)
    end

    def poll_b(force: false, wait_seconds: 5)
      fixture_runner(transport: transport_b)
        .call(event_source: stale, force: force, wait_seconds: wait_seconds)
    end

    it "lets exactly one of them reach GitHub" do
      poll_a
      poll_b

      expect(transport_a.requests.size).to eq(1)
      expect(transport_b.requests).to be_empty
      expect(PushEvent.count).to eq(4)
    end

    # The regression test for the reload. Remove `event_source.reload` from
    # IngestionRunner#call and this example fails while the rest of the suite stays green,
    # because every other poll spec hands the runner a freshly loaded row.
    it "makes the loser re-read the row under the lock and find it not due" do
      poll_a

      expect(poll_b).to be_deferred
      expect(poll_b.deferral_reason).to eq("cadence_due_at")
    end

    # Distinguishes "the row was re-read" from "the object happened to be current". reload
    # mutates in place, so the stale object carries the proof.
    it "proves the reload happened, rather than the cadence merely binding" do
      expect(stale.cadence_due_at).to be_nil

      poll_a
      poll_b

      expect(stale.cadence_due_at).to eq(EventSource.sole.cadence_due_at)
      expect(stale.cadence_due_at).not_to be_nil
    end

    it "opens one run row, not two" do
      poll_a
      poll_b

      expect(IngestionRun.count).to eq(1)
    end

    # §10's ledger is global, so a back-to-back double poll would spend two of the twelve
    # attempts this hour has for a page it already holds.
    it "spends one poll attempt, not two" do
      poll_a
      poll_b

      expect(current_budget.poll_used).to eq(1)
    end

    it "advances the schedule once, to the instant the winner wrote" do
      poll_a
      winner_scheduled = EventSource.sole.next_poll_at

      poll_b

      expect(EventSource.sole.next_poll_at).to eq(winner_scheduled)
    end

    # The line between the two mechanisms, drawn explicitly. §9 licenses --force against the
    # cadence; it licenses nothing against the lock, and SourceLock.acquire wraps the call
    # before `force` is read at all.
    it "still refuses a forced loser while the winner holds the lock" do
      other_session_holding(source_namespace, Github::AdvisoryLock.key_for(stale.id)) do
        expect { poll_b(force: true, wait_seconds: 0) }
          .to raise_error(Github::Errors::SourceBusy)
      end
    end

    it "leaves no lock and no lock-order tracking behind either poller" do
      poll_a
      poll_b

      expect(advisory_lock_holders(source_namespace, Github::AdvisoryLock.key_for(stale.id))).to be_empty
      expect(Github::LockOrder.held_keys).to be_empty
    end
  end

  # ---------------------------------------------------------------------------------------
  # §9, bullet 2 — the global request gate
  # ---------------------------------------------------------------------------------------
  #
  # §2A: "at most one in-flight live request across poller, worker, and one-shot". The poll
  # side of that is covered (spec/services/github/request_executor_spec.rb,
  # ingestion_runner_spec.rb). The enrichment side is not, and it is the side with a lease
  # to put back.
  describe "the global request gate, across both request paths" do
    let(:transport) { fixture_transport }
    let(:configuration) { configuration_with("GITHUB_MODE" => "fixture") }
    let!(:actor) do
      create_actor(github_id: IngestionHelpers::ACTOR_GITHUB_ID, last_seen_at: frozen_time,
                   enrichment_status: "pending",
                   created_at: frozen_time, updated_at: frozen_time)
    end

    # 0.1s, never 0: PostgreSQL reads lock_timeout = 0 as "no timeout", so a zero wait would
    # block forever rather than defer.
    def batch_attempt
      fixture_batch_runner(
        configuration: configuration,
        executor: fixture_executor(transport: transport, request_gate_wait: 0.1,
                                   ledger: ledger_for(configuration),
                                   search_ledger: search_ledger_for(configuration))
      ).call(entity_class: GithubActor)
    end

    def poll_cycle
      fixture_runner(transport: transport, request_gate_wait: 0.1)
        .call(event_source: fixture_event_source)
    end

    it "defers a Search batch rather than failing it" do
      result = other_session_holding(gate_namespace, gate_key) { batch_attempt }

      expect(result.status).to eq("deferred")
      expect(result.deferral_reason).to eq("gate_unavailable")
    end

    it "spends nothing and issues no request while the gate is held" do
      other_session_holding(gate_namespace, gate_key) { batch_attempt }

      expect(current_budget.enrichment_used).to eq(0)
      expect(GithubSearchBudget.find_by(id: GithubSearchBudget::SINGLETON_ID)&.used.to_i).to eq(0)
      expect(transport.requests).to be_empty
    end

    # The assertion this file exists for. A deferred batch still *claimed* the row — it
    # wrote the lease columns and opened a batch row before discovering the gate was
    # busy — so proving the entity is untouched proves BatchClaim#release! restored the
    # row exactly rather than leaving the lease stranded for its full 600s. The batch
    # row itself survives as `deferred` evidence, which is about the window, never the
    # entity.
    it "gives the lease back exactly, leaving the entity byte-identical" do
      before = actor.reload.attributes

      other_session_holding(gate_namespace, gate_key) { batch_attempt }

      expect(actor.reload.attributes).to eq(before)
      expect(EnrichmentBatch.sole.status).to eq("deferred")
    end

    # One gate, application-wide — asserted as a single fact rather than as two separate
    # claims about two subsystems.
    it "stops the poller and the enrichment worker alike" do
      poll_result = nil
      batch_result = nil

      other_session_holding(gate_namespace, gate_key) do
        poll_result = poll_cycle
        batch_result = batch_attempt
      end

      expect(poll_result).to be_deferred
      expect(batch_result.status).to eq("deferred")
      expect(current_budget.poll_used).to eq(0)
      expect(current_budget.enrichment_used).to eq(0)
      expect(transport.requests).to be_empty
    end

    it "leaves the gate free and the lock order clean after both deferrals" do
      other_session_holding(gate_namespace, gate_key) do
        poll_cycle
        batch_attempt
      end

      expect(advisory_lock_holders(gate_namespace, gate_key)).to be_empty
      expect(Github::LockOrder.held_keys).to be_empty
    end
  end

  # ---------------------------------------------------------------------------------------
  # The measurement ADR 0008 deferred to this PR
  # ---------------------------------------------------------------------------------------
  #
  # ADR 0008 rejected Solid Queue's limits_concurrency keyed by event_source_id and said so
  # with a condition attached: "The source lock, the global request gate and the unique event
  # constraint are the protections in force; revisit when PR 11's multi-poller tests can
  # measure a gap." app/jobs/poll_event_source_job.rb repeats it.
  #
  # A gap exists iff, under sustained contention, some observable cost or incorrectness
  # survives that a semaphore keyed by source id would have prevented. Four observables are
  # measured below.
  #
  # VERDICT: no gap. The three protections §9 names are sufficient, and the semaphore is
  # strictly weaker on two of the four axes — it writes to prevent writes that never happen
  # (G2), and its fixed duration outlives a killed container where an advisory lock dies with
  # the session (G3).
  #
  # What this measurement does NOT cover, stated rather than glossed: whether a
  # solid_queue_semaphores round trip is material under N real worker containers is a load
  # question, not a unit one. The verdict is bounded to correctness and local cost.
  describe "the gap ADR 0008 asked PR 11 to measure" do
    let(:transport) { fixture_transport }
    let!(:event_source) { fixture_event_source }
    let(:key) { Github::AdvisoryLock.key_for(event_source.id) }

    before do
      allow(Github).to receive(:configuration).and_return(configuration_with("GITHUB_MODE" => "fixture"))

      allow(Github::IngestionRunner).to receive(:new).and_call_original
      runner = fixture_runner(transport: transport)
      allow(Github::IngestionRunner).to receive(:new).and_return(runner)
    end

    def contended_ticks(count)
      other_session_holding(source_namespace, key) do
        count.times { PollEventSourceJob.new.perform_now }
      end
    end

    # G1 — the four things a semaphore would exist to prevent, measured across a window of
    # ticks rather than a single one.
    it "G1 — sustained contention produces no duplicate request, row, debit or schedule move" do
      before_source = event_source.attributes

      contended_ticks(5)

      expect(IngestionRun.count).to eq(0)
      expect(transport.requests).to be_empty
      expect(current_budget.poll_used).to eq(0)
      expect(PushEvent.count).to eq(0)
      expect(event_source.reload.attributes).to eq(before_source)
    end

    # G2 — the cost comparison. A contended tick writes nothing at all, so a semaphore would
    # spend an INSERT and a DELETE in solid_queue_semaphores to prevent zero writes.
    #
    # The statement *classes* are the load-bearing claim. The count is a smoke bound, not a
    # specification of the query plan: cached and SCHEMA statements are filtered because
    # whether the schema cache is already warm depends on file order under
    # config.order = :random.
    it "G2 — a contended tick costs no write at all, so a semaphore would save nothing" do
      statements = []

      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        next if payload[:name] == "SCHEMA" || payload[:cached]

        statements << payload[:sql]
      end

      begin
        contended_ticks(1)
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      expect(statements.grep(/\A\s*(INSERT|UPDATE|DELETE)/i)).to be_empty
      expect(statements.size).to be < 10
    end

    # G3 — ADR 0008's stated rejection reason, measured rather than argued: "a container
    # killed mid-poll would suppress that source until the semaphore expired. The session
    # advisory lock this system already holds is released by PostgreSQL the instant the
    # backend dies."
    #
    # A limits_concurrency semaphore must declare a fixed `duration` at least as long as the
    # longest legitimate poll, so its floor is tens of seconds. The lock's recovery is
    # measured below and asserted an order of magnitude under one second.
    it "G3 — a killed session frees the source immediately, where a semaphore would not" do
      acquire_in_other_session(source_namespace, key)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      terminate_second_session!
      wait_for_advisory_lock_release(source_namespace, key)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < 1
      expect(Github::SourceLock.acquire(event_source.id, wait_seconds: 5) { :polled }).to eq(:polled)
    end

    # G4 — a semaphore keyed by source id is only as good as the agreement on that id, and
    # nothing about the semaphore provides it. Github::Ingestion::SourceProvisioner does,
    # by converging every process on the lowest id for the type; the mechanism itself is
    # covered by source_provisioner_spec.rb, and what is asserted here is the consequence
    # for the key.
    it "G4 — key agreement comes from the provisioner, not from any concurrency primitive" do
      create_event_source(source_type: "github_fixture_events")

      first = Github::Ingestion::SourceProvisioner.ensure!(mode: :fixture, now: frozen_time)
      second = Github::Ingestion::SourceProvisioner.ensure!(mode: :fixture, now: frozen_time)

      expect(Github::AdvisoryLock.key_for(first.id)).to eq(Github::AdvisoryLock.key_for(second.id))
    end

    # The verdict, made executable. Written in the idiom of spec/job_boundary_spec.rb's and
    # spec/network_boundary_spec.rb's grep guards: if someone later adds a source-keyed
    # concurrency limit, this fails and sends them back to ADR 0008's condition rather than
    # letting the decision be reversed silently.
    it "records the verdict: no job declares a source-keyed concurrency limit" do
      declaring = Dir[Rails.root.join("app/jobs/**/*.rb")].select do |path|
        File.read(path).include?("limits_concurrency")
      end

      expect(declaring).to be_empty
    end
  end
end
