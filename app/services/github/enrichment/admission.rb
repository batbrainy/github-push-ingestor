module Github
  module Enrichment
    # Read-side admission pre-checks for the two enrichment lanes. Advisory only: the
    # ledgers re-check everything under their row locks, and a verdict that passes here
    # can still lose the race there. What the pre-check buys is churn control — a denied
    # tick enqueues no cycle and creates no enrichment_batches row.
    #
    # Never calls bootstrap! and never writes: a read path must not create ledger rows.
    class Admission
      Verdict = Data.define(:reason, :retry_in_seconds) do
        def granted? = reason.nil?
      end

      GRANTED = Verdict.new(reason: nil, retry_in_seconds: nil)

      def initialize(configuration: Github.configuration)
        @configuration = configuration
      end

      attr_reader :configuration

      # Mirrors SearchBudgetLedger#denial_reason in the same order, plus window
      # awareness: counters from an elapsed window are stale, and the ledger will roll
      # them on its next reservation. A missing row is a grant — the search ledger
      # self-bootstraps from configuration, unlike core.
      def search(now: Time.current)
        budget = GithubSearchBudget.find_by(id: GithubSearchBudget::SINGLETON_ID)
        return GRANTED if budget.nil?

        if budget.blocked_until.present? && budget.blocked_until > now
          return deny(:search_blocked, budget.blocked_until - now)
        end
        if budget.last_request_at.present?
          resume_at = budget.last_request_at + configuration.search_pacing_seconds
          return deny(:search_pacing, resume_at - now) if resume_at > now
        end
        return GRANTED if window_elapsed?(budget, now: now)

        if budget.remaining.present? && budget.remaining <= budget.reserve
          return deny(:search_reserve_reached, until_reset(budget, now))
        end
        if budget.used >= budget.request_ceiling - budget.reserve
          return deny(:search_ceiling_exhausted, until_reset(budget, now))
        end

        GRANTED
      end

      # The core detail-fallback lane keeps the core ledger's bootstrap discipline: no
      # window, no enrichment. The same checks the retired per-entity Dispatch made.
      def detail(now: Time.current)
        budget = GithubApiBudget.find_by(id: GithubApiBudget::SINGLETON_ID)
        return deny(:window_uninitialized, nil) if budget.nil? || budget.window_initialized_at.nil?
        return deny(:window_elapsed, nil) if budget.reset_at.present? && now >= budget.reset_at

        if budget.global_blocked_until.present? && budget.global_blocked_until > now
          return deny(:globally_blocked, budget.global_blocked_until - now)
        end
        blocked_until = budget.enrichment_class_blocked_until(now: now)
        if blocked_until.present? && blocked_until > now
          return deny(:class_exhausted, blocked_until - now)
        end

        GRANTED
      end

      private

      def deny(reason, retry_in)
        Verdict.new(reason: reason, retry_in_seconds: retry_in&.to_f)
      end

      def window_elapsed?(budget, now:)
        return now >= budget.reset_at if budget.reset_at.present?

        budget.last_request_at.present? &&
          budget.last_request_at <= now - SearchBudgetLedger::SEARCH_WINDOW_SECONDS &&
          budget.used.positive?
      end

      def until_reset(budget, now)
        budget.reset_at.present? ? budget.reset_at - now : nil
      end
    end
  end
end
