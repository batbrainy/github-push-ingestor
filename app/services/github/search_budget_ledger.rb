module Github
  # A separate persisted ledger for GitHub's minute-scoped Search resource. Core polling
  # and detail fallback never read this row, so Search pressure cannot consume or block
  # the polling allocation.
  #
  # Unlike the core ledger, this one self-initializes from configuration defaults: the
  # search lane needs no bootstrap poll, because the ceiling/reserve pair is a
  # configured budget and the observed x-ratelimit-search headers only tighten it.
  class SearchBudgetLedger
    SINGLETON_ID = GithubSearchBudget::SINGLETON_ID
    SEARCH_CLASSES = %i[actor_search repository_search].freeze

    # GitHub's Search rate-limit window is one minute (a documented API fact, like
    # Configuration::UNAUTHENTICATED_CORE_LIMIT). Used only as the fallback rollover
    # horizon when no response ever supplied reset_at — without it, a run of
    # header-less transport failures would pin `used` at the ceiling forever.
    SEARCH_WINDOW_SECONDS = 60

    DENIAL_REASONS = %i[search_blocked search_pacing search_reserve_reached
                        search_ceiling_exhausted].freeze

    def initialize(configuration: Github.configuration)
      @configuration = configuration
    end

    attr_reader :configuration

    def reserve!(request_class, now: Time.current, borrow: false)
      raise ArgumentError, "Search reservations do not borrow" if borrow
      unless SEARCH_CLASSES.include?(request_class)
        raise ArgumentError, "unknown Search request class #{request_class.inspect}"
      end

      bootstrap!(now: now)

      # §10: a secondary rate limit is IP-scoped, so it stops *all* live requests, not
      # only the resource that provoked it. The two ledgers meter separate resources but
      # share one outbound address, so each honours the other's global block.
      if (blocked_until = global_block(now: now))
        Rails.logger.info(event: "search_budget.globally_blocked",
                          blocked_until: blocked_until.utc.iso8601)
        raise Errors::BudgetExhausted.new(request_class, :globally_blocked)
      end

      reason = nil

      GithubSearchBudget.transaction do
        budget = GithubSearchBudget.lock.find(SINGLETON_ID)
        if window_elapsed?(budget, now: now)
          roll_window!(budget, now: now)
          budget.reload
        end
        reason = denial_reason(budget, now: now)
        if reason
          log_denial(budget, reason)
          next
        end

        budget.update!(
          used: budget.used + 1,
          actor_used: budget.actor_used + (request_class == :actor_search ? 1 : 0),
          repository_used: budget.repository_used + (request_class == :repository_search ? 1 : 0),
          remaining: budget.remaining.nil? ? nil : [ budget.remaining - 1, 0 ].max,
          last_request_at: now,
          updated_at: now
        )
      end

      raise Errors::BudgetExhausted.new(request_class, reason) if reason

      GithubSearchBudget.find(SINGLETON_ID)
    end

    def reconcile!(snapshot, request_class: nil, now: Time.current)
      return :no_headers if snapshot.nil?
      return :resource_mismatch if snapshot.resource.present? && snapshot.resource != "search"

      GithubSearchBudget.transaction do
        budget = GithubSearchBudget.lock.find_by(id: SINGLETON_ID)
        next :no_ledger if budget.nil?
        next :partial_headers unless snapshot.quantitative?

        # The response proves GitHub counted this request in a window later than the one
        # stored here. Carry only the in-flight request's own debit forward — a
        # reconciliation with no request behind it (there is no such caller today, but
        # the signature permits one) carries nothing, keeping
        # used == actor_used + repository_used. The previous window's clamped remaining
        # is dropped with its counters, or the monotonic minimum below would import it
        # into a window GitHub says is fresh.
        if budget.reset_at.present? && snapshot.reset_at > budget.reset_at
          budget.assign_attributes(
            used: request_class ? 1 : 0,
            actor_used: request_class == :actor_search ? 1 : 0,
            repository_used: request_class == :repository_search ? 1 : 0,
            remaining: nil
          )
        end

        budget.limit = snapshot.limit
        budget.remaining = budget.remaining.nil? ? snapshot.remaining :
          [ budget.remaining, snapshot.remaining ].min
        budget.reset_at = snapshot.reset_at
        budget.observed_at = snapshot.observed_at || now
        budget.blocked_until = snapshot.reset_at if budget.remaining <= budget.reserve
        budget.updated_at = now
        budget.save!
        :updated
      end
    end

    # @param core_ledger [Github::BudgetLedger] the writer of global_blocked_until. A
    #   secondary limit provoked by a Search request is IP-scoped like any other, so it
    #   has to stop polling too — §10 is explicit that one timestamp covers every live
    #   request. A primary Search exhaustion is *not* global: it bounds only this
    #   resource, and blocking polling on it would hand the search lane the power to
    #   starve event capture.
    def block_from!(fetched, now: Time.current, core_ledger: BudgetLedger.new)
      return unless %i[rate_limited secondary_limited].include?(fetched.classification)

      snapshot = fetched.rate_limit(observed_at: now)
      retry_seconds = snapshot.retry_after_seconds
      until_at = if retry_seconds.is_a?(Integer) && retry_seconds.positive?
        now + retry_seconds
      else
        snapshot.reset_at || now + SEARCH_WINDOW_SECONDS
      end

      if fetched.classification == :secondary_limited
        core_ledger.block_globally!(until_at: until_at, reason: "search_secondary_limit",
                                    now: now)
      end

      # GREATEST ignores NULL, so a block only ever moves later — the core ledger's
      # BLOCK_SQL rule, restated for the search row.
      GithubSearchBudget.where(id: SINGLETON_ID).update_all(
        blocked_until: Arel::Nodes::NamedFunction.new(
          "GREATEST",
          [ GithubSearchBudget.arel_table[:blocked_until], Arel::Nodes.build_quoted(until_at) ]
        ),
        updated_at: now
      )
      Rails.logger.info(event: "search_budget.blocked",
                        classification: fetched.classification,
                        blocked_until: until_at.utc.iso8601)
    end

    def bootstrap!(now: Time.current)
      GithubSearchBudget.insert_all(
        [ {
          id: SINGLETON_ID,
          request_ceiling: configuration.search_request_ceiling,
          reserve: configuration.search_safety_reserve,
          created_at: now,
          updated_at: now
        } ],
        unique_by: :id
      )
    end

    private

    # The core ledger owns global_blocked_until because a secondary limit can arise on
    # any live request and Github::RateLimitPolicy already writes it there. Read with
    # find_by, never through BudgetLedger: this path must not create that row.
    def global_block(now:)
      blocked_until = GithubApiBudget.find_by(id: GithubApiBudget::SINGLETON_ID)
                                     &.global_blocked_until

      blocked_until if blocked_until&.>(now)
    end

    # The window has moved on when GitHub's own reset instant passed, or — when no
    # response ever told us one — when a full Search window elapsed since the last
    # outbound attempt.
    def window_elapsed?(budget, now:)
      return now >= budget.reset_at if budget.reset_at.present?

      budget.last_request_at.present? &&
        budget.last_request_at <= now - SEARCH_WINDOW_SECONDS &&
        budget.used.positive?
    end

    def denial_reason(budget, now:)
      return :search_blocked if budget.blocked_until.present? && budget.blocked_until > now
      if budget.last_request_at.present? &&
         budget.last_request_at + configuration.search_pacing_seconds > now
        return :search_pacing
      end
      return :search_reserve_reached if budget.remaining.present? && budget.remaining <= budget.reserve

      :search_ceiling_exhausted if budget.used >= budget.request_ceiling - budget.reserve
    end

    def roll_window!(budget, now:)
      Rails.logger.info(event: "search_budget.window_rolled",
                        previous_used: budget.used,
                        previous_actor_used: budget.actor_used,
                        previous_repository_used: budget.repository_used,
                        reset_at: budget.reset_at&.utc&.iso8601)
      budget.update!(used: 0, actor_used: 0, repository_used: 0, remaining: nil,
                     reset_at: nil, blocked_until: nil, updated_at: now)
    end

    def log_denial(budget, reason)
      case reason
      when :search_pacing
        Rails.logger.debug(event: "search_budget.pacing_deferred",
                           last_request_at: budget.last_request_at&.utc&.iso8601,
                           pacing_seconds: configuration.search_pacing_seconds)
      when :search_reserve_reached, :search_ceiling_exhausted
        Rails.logger.info(event: "search_budget.reserve_reached", reason: reason,
                          used: budget.used, request_ceiling: budget.request_ceiling,
                          reserve: budget.reserve, remaining: budget.remaining)
      end
    end
  end
end
