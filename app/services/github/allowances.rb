module Github
  # IMPLEMENTATION_PLAN.md §10's one authoritative allowance formula, and the startup
  # rule derived from it. Deriving rather than configuring the two allowances is the
  # point: storing 12 and 40 alongside the inputs that produce them guarantees they
  # disagree eventually.
  #
  #   poll_allowance       = ceil(3600 / POLL_INTERVAL_SECONDS)
  #                          x MAX_PAGES_PER_POLL x ENABLED_LIVE_SOURCE_COUNT
  #   enrichment_allowance = limit - RATE_LIMIT_RESERVE - poll_allowance
  #
  # With the pinned defaults: ceil(3600/300) x 1 x 1 = 12, and 60 - 8 - 12 = 40.
  #
  # These are request-*attempt* allowances, not guaranteed successful polls: a 500
  # retry or a forced one-shot consumes poll allowance and can reduce the number of
  # completed scheduled polls that hour (§7).
  Allowances = Data.define(:limit, :reserve, :poll_allowance, :enrichment_allowance) do
    class << self
      # The formula exactly as written. enrichment_allowance may come out zero or
      # negative; that is precisely the configuration #feasible? rejects, so it is
      # reported rather than hidden here.
      def derive(configuration:, limit:)
        poll = (3600.0 / configuration.poll_interval_seconds).ceil *
               configuration.max_pages_per_poll *
               configuration.enabled_live_source_count

        new(
          limit: limit,
          reserve: configuration.rate_limit_reserve,
          poll_allowance: poll,
          enrichment_allowance: limit - configuration.rate_limit_reserve - poll
        )
      end
    end

    # §10: startup validation rejects any configuration where
    # poll_allowance + reserve >= limit, because that leaves no capacity for the
    # enrichment Story 3 requires. Stated here as "at least one enrichment attempt",
    # which is the same predicate and says why.
    def feasible?
      enrichment_allowance >= 1
    end

    # What to actually store when the observed limit makes the configuration
    # infeasible — an IP co-tenant scenario, a proxy, or an unexpected tier.
    #
    # Polling wins the clamp: §10 ranks polling first, and enrichment reaching zero is
    # an already-modelled, documented outcome (skipped_budget), whereas polling
    # stopping is a Story 1 failure. Runtime degrades; only boot refuses.
    def clamped
      spendable = [ limit - reserve, 0 ].max
      poll = [ poll_allowance, spendable ].min

      with(poll_allowance: poll, enrichment_allowance: spendable - poll)
    end

    def to_log
      { limit: limit, reserve: reserve,
        poll_allowance: poll_allowance, enrichment_allowance: enrichment_allowance }
    end
  end
end
