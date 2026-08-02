module Github
  module Enrichment
    # §8 step 10's enqueue and step 11's reconciliation, as one rule with two callers.
    #
    # Github::IngestionRunner calls it after a run whose events committed; PR 8's recurring
    # ReconcilePendingEnrichmentsJob calls it every 60 seconds. Both ask the same question —
    # "is there durable enrichment work this class could do right now?" — and the answer is
    # read from the committed entity rows and the ledger, never from the queue. That is what
    # makes the enqueue a *hint*: §2A's outbox-style recovery says "the committed entity
    # state is the durable record of pending work". A process killed between the COMMIT and
    # enqueue can lose that hint while leaving eligible pending entity state discoverable by
    # a later successful reconciler tick.
    #
    # **At most one job per class per call**, however deep the backlog. §5 gives each class
    # one job and Github::EnrichmentRunner enriches at most one entity per call, so the
    # queue depth that matters is set by §10's hourly allowance (40 at the defaults), not by
    # how fast jobs can be created. One live page carries ~90 distinct actors and ~90
    # distinct repositories; enqueuing per created event would put ~2,400 argument-identical
    # cycles an hour on a queue that can spend 40 requests, and every surplus one would run
    # the fairness reads only to be told no. The reconciler's 60-second
    # cadence is what refills the pipeline instead — it is faster than the budget can be
    # spent, and it self-limits when the budget is gone.
    #
    # It takes no lock, opens no transaction, and makes no request.
    class Dispatch
      # Job classes by name, constantized at the call, for EntityType's reason: a constant
      # holding the class object would pin it across a development reload.
      JOBS = { actor: "EnrichActorJob", repository: "EnrichRepositoryJob" }.freeze

      def self.call(reason:, **options)
        new(**options).call(reason: reason)
      end

      def initialize(configuration: Github.configuration, clock: -> { Time.current }, selector: nil)
        @configuration = configuration
        @clock = clock
        @selector = selector || CandidateSelector.new(configuration: configuration)
      end

      # @param reason [String] what asked — "ingestion" or "reconcile". It is on every line
      #   because the two have different meanings when they disagree: an ingestion dispatch
      #   that enqueues nothing means the events created no new work, while a reconcile one
      #   that enqueues means something was committed and never scheduled.
      # @return [Hash] the payload it logged, so a caller can assert on it.
      def call(reason:)
        now = @clock.call
        budget = GithubApiBudget.find_by(id: GithubApiBudget::SINGLETON_ID)
        schedule = class_schedule(budget, now: now)
        window_block = window_blocked_by(budget, now: now)
        schedule_blocked = !schedule.due?(now: now)
        blocked = schedule_blocked || window_block.present?
        blocked_by = schedule_blocked ? schedule.binding_component : window_block

        payload = EntityType.all.each_with_object({}) do |entity_type, counts|
          enqueue = !blocked && @selector.claimable?(entity_type, now: now)
          JOBS.fetch(entity_type.key).constantize.perform_later if enqueue

          counts[:"#{entity_type.key}_enqueued"] = enqueue ? 1 : 0
        end

        log(payload.merge(reason: reason, blocked_by: (blocked_by if blocked)).compact,
            budget: budget, now: now)
      end

      private

      # §9's effective_enrichment_time with the entity component omitted, because this object
      # is not choosing an entity — Github::Enrichment::Claim does that, under a lease, after
      # Github::Enrichment::Fairness has chosen a class. What it can answer cheaply is
      # whether *any* enrichment is legal right now, and both of the remaining components are
      # single reads of one row.
      #
      # The per-class share is deliberately absent, for the reason
      # Github::EnrichmentSchedule's own comment gives: a share exhaustion is a denial
      # relieved by borrowing, not a deferral, so refusing to enqueue on it would withhold
      # work the ledger would have granted.
      #
      # The caller obtains the row with find_by, never bootstrap!: a read path must not
      # create it. A missing or existing-uninitialized ledger blocks dispatch because the
      # request gate would deny enrichment until the first poll supplies authoritative
      # rate-limit headers.
      def class_schedule(budget, now:)
        EnrichmentSchedule.new(
          next_retry_at: nil,
          global_blocked_until: budget&.global_blocked_until,
          enrichment_class_blocked_until: budget&.enrichment_class_blocked_until(now: now)
        )
      end

      def window_blocked_by(budget, now:)
        return :window_uninitialized if budget.nil? || budget.window_initialized_at.nil?
        :window_elapsed if budget.reset_at.present? && now >= budget.reset_at
      end

      # §11 lists "reconciliation summaries" among the INFO events, and this is that line —
      # but only when it scheduled something. A tick that enqueued nothing is the ordinary
      # steady state of an exhausted window, and at 60-second cadence it would emit a line a
      # minute for the rest of the hour: the volume argument
      # Github::BudgetLedger#log_class_exhausted and Github::EnrichmentRunner#log already make.
      #
      # The summary is PR 7's, unchanged: per-status counts per class, per-class share usage,
      # the window state, and when enrichment is next due.
      def log(payload, budget:, now:)
        enqueued = payload.fetch(:actor_enqueued) + payload.fetch(:repository_enqueued)
        entry = { event: "enrichment.dispatched", **payload,
                  **Summary.capture(now: now, configuration: @configuration,
                                    selector: @selector, budget: budget).to_log }

        enqueued.positive? ? Rails.logger.info(entry) : Rails.logger.debug(entry)
        payload
      end
    end
  end
end
