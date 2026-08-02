module Github
  module Enrichment
    # §8 step 10's enqueue and step 11's reconciliation, as one rule with two callers.
    #
    # Github::IngestionRunner calls it after a run whose events committed; the recurring
    # ReconcilePendingEnrichmentsJob calls it every 60 seconds. Both ask the same
    # question — "is there staged enrichment work a cycle could do right now?" — and the
    # answer is read from the committed entity rows and the two ledgers, never from the
    # queue. That is what makes the enqueue a *hint*: §2A's outbox-style recovery says
    # the committed entity state is the durable record of pending work. A process killed
    # between COMMIT and enqueue loses the hint while leaving the work discoverable by a
    # later reconciler tick.
    #
    # **At most one cycle per call**, however deep the backlog: EnrichmentCycleJob loops
    # until a ledger denies, so queue depth is set by the budgets, not by how fast jobs
    # can be created. This is also the churn gate — a tick with nothing admissible
    # enqueues nothing, so an exhausted hour creates no cycle jobs and no batch rows.
    #
    # It takes no lock, opens no transaction, and makes no request.
    class Dispatch
      # Constantized at the call, for EntityType's reason: a constant holding the class
      # object would pin it across a development reload.
      JOB = "EnrichmentCycleJob".freeze

      def self.call(reason:, **options)
        new(**options).call(reason: reason)
      end

      def initialize(configuration: Github.configuration, clock: -> { Time.current },
                     admission: nil, batch_claim: nil, detail_claim: nil)
        @configuration = configuration
        @clock = clock
        @admission = admission || Admission.new(configuration: configuration)
        @batch_claim = batch_claim || BatchClaim.new(configuration: configuration)
        @detail_claim = detail_claim || DetailClaim.new(configuration: configuration)
      end

      # @param reason [String] what asked — "ingestion" or "reconcile". An ingestion
      #   dispatch that enqueues nothing means the events created no admissible work; a
      #   reconcile one that enqueues means something committed was never scheduled.
      # @return [Hash] the payload it logged, so a caller can assert on it.
      def call(reason:)
        now = @clock.call

        search_verdict = @admission.search(now: now)
        detail_verdict = @admission.detail(now: now)

        # Pacing is admissible: the cycle can wait it out. Everything else is not.
        search_admissible = search_verdict.granted? || search_verdict.reason == :search_pacing
        batch_work = search_admissible &&
                     EntityType.all.any? { |type| @batch_claim.claimable?(type, now: now) }
        detail_work = detail_verdict.granted? &&
                      EntityType.all.any? { |type| @detail_claim.claimable?(type, now: now) }

        enqueue = batch_work || detail_work
        JOB.constantize.perform_later if enqueue

        blocked_by = unless enqueue
          [ (search_verdict.reason || :no_batch_work),
            (detail_verdict.reason || :no_detail_work) ]
        end

        log({ cycle_enqueued: enqueue ? 1 : 0, reason: reason,
              blocked_by: blocked_by }.compact)
      end

      private

      # INFO only when it scheduled something: a tick that enqueued nothing is the
      # ordinary steady state of an exhausted window, and at 60-second cadence it would
      # emit a line a minute for the rest of the hour. The rich per-stage summary lives
      # on /status and the one-shot, not on this line.
      def log(payload)
        entry = { event: "enrichment.dispatched", **payload }
        payload.fetch(:cycle_enqueued).positive? ? Rails.logger.info(entry) : Rails.logger.debug(entry)
        payload
      end
    end
  end
end
