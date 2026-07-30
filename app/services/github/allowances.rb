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
  #
  # §10 then splits the enrichment allowance between the two entity classes:
  #
  #   actor_guarantee      = floor(enrichment_allowance x ACTOR_ENRICHMENT_SHARE)
  #   repository_guarantee = enrichment_allowance - actor_guarantee
  #
  # The share is a member because it is an input; the two guarantees are methods because
  # they are derived, and the difference is load-bearing. #clamped rewrites
  # enrichment_allowance, and members would have frozen guarantees computed from the
  # pre-clamp total into the clamped copy.
  class Allowances < Data.define(:limit, :reserve, :poll_allowance, :enrichment_allowance,
                                 :actor_enrichment_share)
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
          enrichment_allowance: limit - configuration.rate_limit_reserve - poll,
          actor_enrichment_share: configuration.actor_enrichment_share
        )
      end

      # §10's fairness split, as a pure function of the two numbers it needs, so that
      # Github::BudgetLedger can apply it to the *stored* enrichment_allowance under the
      # row lock rather than to a freshly derived one. ADR 0004 fixes the allowances at
      # window initialization and rollover; a guarantee derived mid-window from a
      # different total than the class cap is checked against could exceed it.
      #
      # The remainder goes to repository because §10 writes the formula that way — actor
      # is floored, repository is the subtraction. That is what makes
      # actor + repository == enrichment_allowance hold for *every* share and every
      # allowance, including odd ones, zero, and the negative one an infeasible
      # configuration produces before #clamped.
      #
      # Keyed by Request::ENRICHMENT_CLASSES so a caller can fetch(request_class).
      def split(enrichment_allowance, actor_enrichment_share)
        actor = (enrichment_allowance * actor_enrichment_share).floor

        { actor: actor, repository: enrichment_allowance - actor }
      end
    end

    def guarantees = self.class.split(enrichment_allowance, actor_enrichment_share)
    def actor_guarantee = guarantees.fetch(:actor)
    def repository_guarantee = guarantees.fetch(:repository)

    # §10: startup validation rejects any configuration where
    # poll_allowance + reserve >= limit, because that leaves no capacity for the
    # enrichment Story 3 requires. Stated here as "at least one enrichment attempt",
    # which is the same predicate and says why.
    #
    # Deliberately about the total and not about either guarantee. §10's rejection rule
    # is about capacity for Story 3, and one attempt of capacity is one attempt of
    # capacity whichever class holds it — a zero guarantee is relieved by borrowing.
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

    # The guarantees rather than the share: they are the numbers that actually bind, and
    # they are what an operator greps when actor enrichment stops at nineteen. The share
    # is recoverable from the pair, and §11 sizes this stream deliberately.
    def to_log
      { limit: limit, reserve: reserve,
        poll_allowance: poll_allowance, enrichment_allowance: enrichment_allowance,
        actor_guarantee: actor_guarantee, repository_guarantee: repository_guarantee }
    end
  end
end
