module Github
  module Enrichment
    # One worker cycle over the staged pipeline: as many Search batches as the search
    # ledger will grant (waiting out pacing when the wait fits), then as many detail
    # fallbacks as the core allowance will grant, all inside one wall-clock budget that
    # keeps a cycle shorter than the 60-second dispatch tick.
    #
    # This is the shape that reaches catch-up throughput: at the defaults — ceiling 10,
    # reserve 2, pacing 6s, batches of 10 — one cycle can move ~80 entities/minute
    # (~4,800/hour theoretical) where a job-per-request design at the tick cadence
    # could never exceed ~1,200/hour. The pacing sleep happens here, on the dedicated
    # single-thread enrichment worker, never inside a gate hold or a ledger lock.
    #
    # The cycle budget bounds when a *new* request may start, not how long one already
    # in flight may take: a single fetch can legitimately run to the gate wait plus its
    # timeouts across every retry and redirect hop, which exceeds the budget. Nothing
    # preempts it, and nothing should — the reservation is already spent. The overrun is
    # bounded by Configuration#worst_case_fetch_seconds and is safe to overlap the next
    # tick: the enrichment queue has one thread, so a cycle enqueued meanwhile waits
    # rather than running beside this one, and it finds the pacing and ceiling state
    # this cycle left behind.
    class CycleRunner
      # Two consecutive idle claims (a claimable? race that found nothing to lock)
      # end the phase rather than spinning on it.
      MAX_CONSECUTIVE_IDLE = 2

      class Cycle < Data.define(:batches_attempted, :batches_completed, :batches_deferred,
                                :batches_failed, :items_requested, :items_valid,
                                :fallbacks_admitted, :details_attempted, :details_completed,
                                :details_terminal, :details_deferred,
                                :batch_stop_reason, :detail_stop_reason, :duration_ms)
        def to_log = to_h.compact
      end

      # Weighted round-robin over the two lanes, borrowing the slot when the scheduled
      # lane has nothing claimable. For search batches the borrow is purely a
      # scheduling fact — the search ledger has no per-lane caps and its actor_used /
      # repository_used counters exist for observability. For detail requests the flag
      # travels to the core ledger, which enforces the 2/2 share split under its row
      # lock exactly as before.
      class LaneSchedule
        def initialize(actor_weight:, repository_weight:)
          @rotation = ([ :actor ] * actor_weight) + ([ :repository ] * repository_weight)
          @cursor = 0
        end

        # @param claimable [Proc] lane key -> Boolean
        # @return [Array(Symbol, Boolean), nil] the lane to run, and whether the *other*
        #   class has no claimable candidate — which is what a borrow asserts to
        #   Github::BudgetLedger. It is deliberately not "this slot was borrowed": a
        #   one-sided backlog would then stop at its own guarantee on every scheduled
        #   turn, even though the capacity it needs is provably idle.
        def next_claimable(claimable)
          scheduled = @rotation[@cursor % @rotation.length]
          @cursor += 1
          other = scheduled == :actor ? :repository : :actor

          lane = if claimable.call(scheduled) then scheduled
          elsif claimable.call(other) then other
          end
          return nil if lane.nil?

          [ lane, !claimable.call(lane == :actor ? :repository : :actor) ]
        end
      end

      def initialize(configuration: Github.configuration,
                     batch_runner: BatchRunner.new(configuration: configuration),
                     detail_runner: DetailRunner.new(configuration: configuration),
                     admission: Admission.new(configuration: configuration),
                     batch_claim: BatchClaim.new(configuration: configuration),
                     detail_claim: DetailClaim.new(configuration: configuration),
                     clock: -> { Time.current },
                     monotonic: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                     sleeper: ->(seconds) { Kernel.sleep(seconds) })
        @configuration = configuration
        @batch_runner = batch_runner
        @detail_runner = detail_runner
        @admission = admission
        @batch_claim = batch_claim
        @detail_claim = detail_claim
        @clock = clock
        @monotonic = monotonic
        @sleeper = sleeper
      end

      def call
        started = @monotonic.call
        @deadline = started + @configuration.enrichment_cycle_budget_seconds
        @tally = Hash.new(0)

        batch_stop = batch_phase
        detail_stop = detail_phase

        cycle = Cycle.new(
          batches_attempted: @tally[:batches_attempted],
          batches_completed: @tally[:batches_completed],
          batches_deferred: @tally[:batches_deferred],
          batches_failed: @tally[:batches_failed],
          items_requested: @tally[:items_requested],
          items_valid: @tally[:items_valid],
          fallbacks_admitted: @tally[:fallbacks_admitted],
          details_attempted: @tally[:details_attempted],
          details_completed: @tally[:details_completed],
          details_terminal: @tally[:details_terminal],
          details_deferred: @tally[:details_deferred],
          batch_stop_reason: batch_stop.to_s,
          detail_stop_reason: detail_stop.to_s,
          duration_ms: ((@monotonic.call - started) * 1000).round
        )
        Rails.logger.info(event: "enrichment.cycle_completed", **cycle.to_log)
        cycle
      end

      private

      def batch_phase
        lanes = LaneSchedule.new(actor_weight: @configuration.actor_enrichment_weight,
                                 repository_weight: @configuration.repository_enrichment_weight)
        idle_streak = 0

        loop do
          return :cycle_budget if @monotonic.call >= @deadline

          verdict = @admission.search(now: @clock.call)
          unless verdict.granted?
            next if waited_out_pacing?(verdict)

            return verdict.reason
          end

          choice = lanes.next_claimable(->(lane) { @batch_claim.claimable?(EntityType.fetch(lane), now: @clock.call) })
          return :no_batch_work if choice.nil?

          result = @batch_runner.call(entity_class: choice.first)
          case result.status
          when "idle"
            idle_streak += 1
            return :no_batch_work if idle_streak >= MAX_CONSECUTIVE_IDLE
          when "deferred"
            # The ledger's denial under its lock outranks the advisory pre-check.
            tally_batch(result)
            return result.deferral_reason
          else
            idle_streak = 0
            tally_batch(result)
          end
        end
      end

      def detail_phase
        lanes = LaneSchedule.new(actor_weight: @configuration.actor_enrichment_weight,
                                 repository_weight: @configuration.repository_enrichment_weight)
        idle_streak = 0

        loop do
          return :cycle_budget if @monotonic.call >= @deadline

          verdict = @admission.detail(now: @clock.call)
          return verdict.reason unless verdict.granted?

          choice = lanes.next_claimable(->(lane) { @detail_claim.claimable?(EntityType.fetch(lane), now: @clock.call) })
          return :no_detail_work if choice.nil?

          lane, borrowed = choice
          result = @detail_runner.call(entity_class: lane, borrow: borrowed)
          case result.status
          when "idle"
            idle_streak += 1
            return :no_detail_work if idle_streak >= MAX_CONSECUTIVE_IDLE
          when "deferred"
            @tally[:details_attempted] += 1
            @tally[:details_deferred] += 1
            return result.reason
          else
            idle_streak = 0
            @tally[:details_attempted] += 1
            @tally[:details_completed] += 1 if result.status == "completed"
            @tally[:details_terminal] += 1 if result.status == "terminal"
          end
        end
      end

      # A pacing wait that fits before the deadline is slept through; one that does
      # not ends the phase — the next tick's cycle resumes exactly where this left off.
      def waited_out_pacing?(verdict)
        return false unless verdict.reason == :search_pacing
        return false if verdict.retry_in_seconds.nil?
        return false if @monotonic.call + verdict.retry_in_seconds >= @deadline

        @sleeper.call(verdict.retry_in_seconds)
        true
      end

      def tally_batch(result)
        @tally[:batches_attempted] += 1
        @tally[:batches_completed] += 1 if result.status == "completed"
        @tally[:batches_deferred] += 1 if result.status == "deferred"
        @tally[:batches_failed] += 1 if result.status == "failed"
        @tally[:items_requested] += result.requested_count
        @tally[:items_valid] += result.valid_count
        @tally[:fallbacks_admitted] += result.fallback_count
      end
    end
  end
end
