require "rails_helper"

# One worker cycle over the staged pipeline. The collaborators are verifying doubles:
# this file is about the loop — admission before every request, weighted lane rotation
# with borrowing, pacing waits inside the deadline, and the stop-reason bookkeeping —
# not about what the runners do once called (their own specs prove that).
RSpec.describe Github::Enrichment::CycleRunner do
  let(:batch_runner) { instance_double(Github::Enrichment::BatchRunner) }
  let(:detail_runner) { instance_double(Github::Enrichment::DetailRunner) }
  let(:admission) { instance_double(Github::Enrichment::Admission) }
  let(:batch_claim) { instance_double(Github::Enrichment::BatchClaim) }
  let(:detail_claim) { instance_double(Github::Enrichment::DetailClaim) }

  let(:granted) { Github::Enrichment::Admission::GRANTED }

  def verdict(reason, retry_in: nil)
    Github::Enrichment::Admission::Verdict.new(reason: reason, retry_in_seconds: retry_in)
  end

  def batch_result(status:, entity_type: :actor, requested: 0, valid: 0, fallback: 0, reason: nil)
    Github::Enrichment::BatchRunner::Result.new(
      status: status, entity_type: entity_type, batch_id: 1, requested_count: requested,
      returned_count: valid, valid_count: valid, fallback_count: fallback,
      deferral_reason: reason
    )
  end

  def detail_result(status:, entity_type: :actor, reason: nil)
    Github::Enrichment::DetailRunner::Result.new(status: status, entity_type: entity_type,
                                                 github_id: 9, batch_id: 2, reason: reason)
  end

  def cycle_runner(configuration: Github.configuration, monotonic: -> { 0.0 },
                   sleeper: ->(_seconds) { })
    described_class.new(configuration: configuration, batch_runner: batch_runner,
                        detail_runner: detail_runner, admission: admission,
                        batch_claim: batch_claim, detail_claim: detail_claim,
                        clock: -> { frozen_time }, monotonic: monotonic, sleeper: sleeper)
  end

  # Most examples focus on one phase; the other is stopped at its first admission.
  def quiet_detail_phase
    allow(admission).to receive(:detail).and_return(verdict(:class_exhausted, retry_in: 120.0))
  end

  def quiet_batch_phase
    allow(admission).to receive(:search).and_return(verdict(:search_ceiling_exhausted,
                                                            retry_in: 30.0))
  end

  describe "the batch phase" do
    it "runs batches until admission denies, and stops with the denial reason" do
      quiet_detail_phase
      allow(admission).to receive(:search)
        .and_return(granted, granted, verdict(:search_ceiling_exhausted, retry_in: 30.0))
      allow(batch_claim).to receive(:claimable?).and_return(true)
      lanes = []
      allow(batch_runner).to receive(:call) do |entity_class:|
        lanes << entity_class
        batch_result(status: "completed", requested: 10, valid: 9, fallback: 1)
      end

      cycle = cycle_runner.call

      expect(cycle).to have_attributes(
        batches_attempted: 2, batches_completed: 2, batches_failed: 0,
        items_requested: 20, items_valid: 18, fallbacks_admitted: 2,
        batch_stop_reason: "search_ceiling_exhausted"
      )
      # Default weights 1/1 alternate the lanes.
      expect(lanes).to eq([ :actor, :repository ])
    end

    it "sleeps out a pacing wait that fits the deadline, then resumes the loop" do
      quiet_detail_phase
      allow(admission).to receive(:search)
        .and_return(verdict(:search_pacing, retry_in: 6.0), granted,
                    verdict(:search_reserve_reached, retry_in: 30.0))
      allow(batch_claim).to receive(:claimable?).and_return(true)
      allow(batch_runner).to receive(:call)
        .and_return(batch_result(status: "completed", requested: 10, valid: 10))
      sleeps = []
      elapsed = { seconds: 0.0 }
      runner = cycle_runner(monotonic: -> { elapsed[:seconds] },
                            sleeper: ->(seconds) { sleeps << seconds; elapsed[:seconds] += seconds })

      cycle = runner.call

      expect(sleeps).to eq([ 6.0 ])
      expect(cycle).to have_attributes(batches_attempted: 1,
                                       batch_stop_reason: "search_reserve_reached")
    end

    it "does not sleep a pacing wait that would cross the deadline — it stops instead" do
      quiet_detail_phase
      allow(admission).to receive(:search).and_return(verdict(:search_pacing, retry_in: 60.0))
      sleeps = []
      runner = cycle_runner(sleeper: ->(seconds) { sleeps << seconds })

      cycle = runner.call

      # batch_runner carries no stub here: a call would raise on the verifying double,
      # so reaching the expectations is itself proof no batch was attempted.
      expect(sleeps).to be_empty
      expect(cycle.batch_stop_reason).to eq("search_pacing")
      expect(cycle.batches_attempted).to eq(0)
    end

    # The ledger re-checks under its row lock; its denial outranks the advisory
    # pre-check that had already granted this iteration.
    it "stops the phase with the ledger's reason when the batch itself was deferred" do
      quiet_detail_phase
      allow(admission).to receive(:search).and_return(granted)
      allow(batch_claim).to receive(:claimable?).and_return(true)
      allow(batch_runner).to receive(:call)
        .and_return(batch_result(status: "deferred", requested: 10, reason: "rate_limited"))

      cycle = cycle_runner.call

      expect(cycle).to have_attributes(batches_attempted: 1, batches_deferred: 1,
                                       batch_stop_reason: "rate_limited")
    end

    it "stops after two consecutive idle claims rather than spinning" do
      quiet_detail_phase
      allow(admission).to receive(:search).and_return(granted)
      allow(batch_claim).to receive(:claimable?).and_return(true)
      allow(batch_runner).to receive(:call).and_return(batch_result(status: "idle"))

      cycle = cycle_runner.call

      expect(batch_runner).to have_received(:call).twice
      expect(cycle).to have_attributes(batches_attempted: 0, batch_stop_reason: "no_batch_work")
    end

    it "honors the configured lane weights: actor 2 / repository 1 schedules A A R" do
      quiet_detail_phase
      allow(admission).to receive(:search)
        .and_return(granted, granted, granted, verdict(:search_ceiling_exhausted, retry_in: 30.0))
      allow(batch_claim).to receive(:claimable?).and_return(true)
      lanes = []
      allow(batch_runner).to receive(:call) do |entity_class:|
        lanes << entity_class
        batch_result(status: "completed", requested: 10, valid: 10)
      end
      runner = cycle_runner(configuration: configuration_with(ACTOR_ENRICHMENT_WEIGHT: "2"))

      runner.call

      expect(lanes).to eq([ :actor, :actor, :repository ])
    end

    it "borrows the slot for the other lane when the scheduled lane has nothing claimable" do
      quiet_detail_phase
      allow(admission).to receive(:search)
        .and_return(granted, verdict(:search_ceiling_exhausted, retry_in: 30.0))
      allow(batch_claim).to receive(:claimable?) do |entity_type, now:|
        entity_type.key == :repository
      end
      lanes = []
      allow(batch_runner).to receive(:call) do |entity_class:|
        lanes << entity_class
        batch_result(status: "completed", requested: 10, valid: 10)
      end

      cycle_runner.call

      expect(lanes).to eq([ :repository ])
    end

    it "stops with no_batch_work when neither lane has anything claimable" do
      quiet_detail_phase
      allow(admission).to receive(:search).and_return(granted)
      allow(batch_claim).to receive(:claimable?).and_return(false)

      cycle = cycle_runner.call

      expect(cycle.batch_stop_reason).to eq("no_batch_work")
    end
  end

  describe "the detail phase" do
    it "mirrors the loop: runs until admission denies, stopping with that reason" do
      quiet_batch_phase
      allow(admission).to receive(:detail)
        .and_return(granted, granted, verdict(:class_exhausted, retry_in: 120.0))
      allow(detail_claim).to receive(:claimable?).and_return(true)
      allow(detail_runner).to receive(:call)
        .and_return(detail_result(status: "completed"), detail_result(status: "terminal",
                                                                      reason: "entity_gone_404"))

      cycle = cycle_runner.call

      expect(cycle).to have_attributes(
        details_attempted: 2, details_completed: 1, details_terminal: 1,
        detail_stop_reason: "class_exhausted"
      )
    end

    # A borrowed detail slot is a real authorization: it reaches the core ledger's
    # share check through the runner's borrow flag.
    it "passes borrow: true to the runner when the slot was borrowed from the other lane" do
      quiet_batch_phase
      allow(admission).to receive(:detail)
        .and_return(granted, verdict(:class_exhausted, retry_in: 120.0))
      allow(detail_claim).to receive(:claimable?) do |entity_type, now:|
        entity_type.key == :repository
      end
      allow(detail_runner).to receive(:call)
        .and_return(detail_result(status: "completed", entity_type: :repository))

      cycle_runner.call

      expect(detail_runner).to have_received(:call).with(entity_class: :repository, borrow: true)
    end

    it "passes borrow: false when the scheduled lane claimed its own slot" do
      quiet_batch_phase
      allow(admission).to receive(:detail)
        .and_return(granted, verdict(:class_exhausted, retry_in: 120.0))
      allow(detail_claim).to receive(:claimable?).and_return(true)
      allow(detail_runner).to receive(:call).and_return(detail_result(status: "completed"))

      cycle_runner.call

      expect(detail_runner).to have_received(:call).with(entity_class: :actor, borrow: false)
    end

    # The borrow states a fact about the *other* class, not about which slot was taken.
    # A one-sided backlog is the case that separates the two readings: the actor lane is
    # scheduled and claims its own slot, and repository work is provably absent, so the
    # ledger is told it may spend past the actor guarantee. Reporting borrow: false here
    # would strand a one-sided backlog at half the allowance with the rest idle.
    it "borrows on its own scheduled turn when the other class has nothing claimable" do
      quiet_batch_phase
      allow(admission).to receive(:detail)
        .and_return(granted, verdict(:class_exhausted, retry_in: 120.0))
      allow(detail_claim).to receive(:claimable?) do |entity_type, now:|
        entity_type.key == :actor
      end
      allow(detail_runner).to receive(:call).and_return(detail_result(status: "completed"))

      cycle_runner.call

      expect(detail_runner).to have_received(:call).with(entity_class: :actor, borrow: true)
    end

    it "stops the phase when a detail request comes back deferred" do
      quiet_batch_phase
      allow(admission).to receive(:detail).and_return(granted)
      allow(detail_claim).to receive(:claimable?).and_return(true)
      allow(detail_runner).to receive(:call)
        .and_return(detail_result(status: "deferred", reason: "rate_limited"))

      cycle = cycle_runner.call

      expect(cycle).to have_attributes(details_attempted: 1, details_deferred: 1,
                                       detail_stop_reason: "rate_limited")
    end
  end

  describe "the cycle budget" do
    # The deadline is monotonic: a clock already past it stops both phases before
    # either consults admission. Neither admission method carries a stub here, so a
    # single admission call would raise on the verifying double.
    it "stops both phases with cycle_budget once the monotonic deadline has passed" do
      ticks = [ 0.0, 100.0, 100.0, 100.0 ]
      runner = cycle_runner(monotonic: -> { ticks.shift || 100.0 })

      cycle = runner.call

      expect(cycle).to have_attributes(batch_stop_reason: "cycle_budget",
                                       detail_stop_reason: "cycle_budget",
                                       duration_ms: 100_000)
    end
  end

  describe "the completed cycle" do
    it "aggregates both phases' counters and emits the INFO summary" do
      allow(Rails.logger).to receive(:info)
      allow(admission).to receive(:search)
        .and_return(granted, granted, verdict(:search_ceiling_exhausted, retry_in: 30.0))
      allow(admission).to receive(:detail)
        .and_return(granted, verdict(:class_exhausted, retry_in: 120.0))
      allow(batch_claim).to receive(:claimable?).and_return(true)
      allow(detail_claim).to receive(:claimable?).and_return(true)
      allow(batch_runner).to receive(:call)
        .and_return(batch_result(status: "completed", requested: 10, valid: 8, fallback: 2),
                    batch_result(status: "failed", requested: 5))
      allow(detail_runner).to receive(:call).and_return(detail_result(status: "completed"))

      cycle = cycle_runner.call

      expect(cycle).to have_attributes(
        batches_attempted: 2, batches_completed: 1, batches_failed: 1, batches_deferred: 0,
        items_requested: 15, items_valid: 8, fallbacks_admitted: 2,
        details_attempted: 1, details_completed: 1, details_terminal: 0,
        batch_stop_reason: "search_ceiling_exhausted", detail_stop_reason: "class_exhausted"
      )
      expect(cycle.duration_ms).to be >= 0
      expect(Rails.logger).to have_received(:info).with(
        hash_including(event: "enrichment.cycle_completed", batches_attempted: 2,
                       details_attempted: 1, batch_stop_reason: "search_ceiling_exhausted")
      )
    end
  end
end
