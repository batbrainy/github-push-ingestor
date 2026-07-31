module Github
  module Status
    # The ledger half of IMPLEMENTATION_PLAN.md §11's /status: "window status, per-class
    # used/allowance (actor_requests_used/available, repository_requests_used/available,
    # poll used/allowance), remaining, reset_at, global_blocked_until, reserve."
    #
    # A projection of one already-loaded row plus one pure split. It issues no query of its
    # own — Github::Status::Snapshot reads github_api_budget once and hands the row down,
    # so every block of one response describes the same instant.
    class LedgerState < Data.define(:present, :resource, :window_status, :limit, :remaining,
                                    :reset_at, :observed_at, :window_initialized_at,
                                    :reserve, :global_blocked_until,
                                    :poll_used, :poll_allowance,
                                    :enrichment_used, :enrichment_allowance,
                                    :actor_share_used, :repository_share_used,
                                    :actor_guarantee, :repository_guarantee)
      class << self
        # @param budget [GithubApiBudget, nil] nil on a clean checkout. Nothing seeds the
        #   row; only a reservation creates it.
        def from(budget, configuration: Github.configuration)
          return absent if budget.nil?

          guarantees = guarantees_for(budget, configuration)

          new(present: true, resource: budget.resource, window_status: budget.window_status,
              limit: budget.limit, remaining: budget.remaining, reset_at: budget.reset_at,
              observed_at: budget.observed_at,
              window_initialized_at: budget.window_initialized_at, reserve: budget.reserve,
              global_blocked_until: budget.global_blocked_until,
              poll_used: budget.poll_used, poll_allowance: budget.poll_allowance,
              enrichment_used: budget.enrichment_used,
              enrichment_allowance: budget.enrichment_allowance,
              actor_share_used: budget.actor_share_used,
              repository_share_used: budget.repository_share_used,
              actor_guarantee: guarantees.fetch(:actor),
              repository_guarantee: guarantees.fetch(:repository))
        end

        # Every field null and one boolean saying why. "No ledger row at all" and "a window
        # whose remaining is genuinely 0" are different facts an operator acts on
        # differently, and without this flag both would render as an all-null-or-zero block.
        # Spelled out rather than derived from .members so the null set is visible here.
        def absent
          new(present: false, resource: nil, window_status: nil, limit: nil, remaining: nil,
              reset_at: nil, observed_at: nil, window_initialized_at: nil, reserve: nil,
              global_blocked_until: nil, poll_used: nil, poll_allowance: nil,
              enrichment_used: nil, enrichment_allowance: nil, actor_share_used: nil,
              repository_share_used: nil, actor_guarantee: nil, repository_guarantee: nil)
        end

        private

        # Derived from the ledger's **stored** enrichment_allowance, never from a fresh
        # Allowances.derive. The allowances are fixed when the window is initialized and
        # again when it rolls; a guarantee recomputed mid-window from a different total
        # than the one reservations are checked against could exceed it, and /status would
        # report headroom the ledger would refuse. The same call
        # Github::Enrichment::Summary and Github::BudgetLedger#share_cap both make.
        def guarantees_for(budget, configuration)
          Allowances.split(budget.enrichment_allowance, configuration.actor_enrichment_share)
        end
      end

      # §11 writes "actor_requests_used/available". `available` never appears without the
      # guarantee that produced it: on its own it cannot be told from the denominator, and
      # a reader cannot check the subtraction.
      #
      # It is a **floor, not a ceiling**, and the distinction is load-bearing. §10 lets one
      # class borrow the other's unspent capacity when the other has no currently eligible
      # candidate, so a class does not stop at zero available — the real ceiling is the
      # enrichment pair beside it. Clamped at zero because borrowing is what makes
      # share_used exceed the guarantee, and a negative "available" reads as an accounting
      # error rather than as the borrow it actually is.
      def actor_available = available(actor_share_used, actor_guarantee)
      def repository_available = available(repository_share_used, repository_guarantee)

      def payload
        { present: present, resource: resource, window_status: window_status,
          limit: limit, remaining: remaining,
          reset_at: Ingestion::Report.timestamp(reset_at),
          observed_at: Ingestion::Report.timestamp(observed_at),
          window_initialized_at: Ingestion::Report.timestamp(window_initialized_at),
          reserve: reserve,
          global_blocked_until: Ingestion::Report.timestamp(global_blocked_until),
          poll: { used: poll_used, allowance: poll_allowance },
          enrichment: { used: enrichment_used, allowance: enrichment_allowance },
          actor_requests: { used: actor_share_used, guarantee: actor_guarantee,
                            available: actor_available },
          repository_requests: { used: repository_share_used,
                                 guarantee: repository_guarantee,
                                 available: repository_available } }
      end

      private

      def available(used, guarantee)
        return nil if used.nil? || guarantee.nil?

        [ guarantee - used, 0 ].max
      end
    end
  end
end
