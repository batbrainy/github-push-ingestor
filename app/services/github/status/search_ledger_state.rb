module Github
  module Status
    # The Search-resource half of the budget story: a projection of the one
    # github_search_budget row plus the pacing arithmetic. It issues no query of its
    # own — Github::Status::Snapshot reads the singleton once and hands the row down,
    # the same single-read discipline LedgerState holds for core.
    class SearchLedgerState < Data.define(:present, :resource, :limit, :remaining,
                                          :reset_at, :observed_at, :request_ceiling,
                                          :reserve, :spendable, :used, :actor_used,
                                          :repository_used, :available, :blocked_until,
                                          :last_request_at, :next_request_earliest_at)
      class << self
        # @param budget [GithubSearchBudget, nil] nil until the first search reservation
        #   creates the row from configuration — unlike core, no poll is involved.
        def from(budget, configuration: Github.configuration, now: Time.current)
          return absent if budget.nil?

          new(present: true, resource: budget.resource, limit: budget.limit,
              remaining: budget.remaining, reset_at: budget.reset_at,
              observed_at: budget.observed_at, request_ceiling: budget.request_ceiling,
              reserve: budget.reserve,
              spendable: budget.request_ceiling - budget.reserve,
              used: budget.used, actor_used: budget.actor_used,
              repository_used: budget.repository_used, available: budget.available,
              blocked_until: budget.blocked_until, last_request_at: budget.last_request_at,
              next_request_earliest_at: next_request_earliest_at(budget, configuration, now))
        end

        def absent
          new(present: false, resource: nil, limit: nil, remaining: nil, reset_at: nil,
              observed_at: nil, request_ceiling: nil, reserve: nil, spendable: nil,
              used: nil, actor_used: nil, repository_used: nil, available: nil,
              blocked_until: nil, last_request_at: nil, next_request_earliest_at: nil)
        end

        private

        # The instant pacing and any block next permit a Search request; null when a
        # request is permitted right now.
        def next_request_earliest_at(budget, configuration, now)
          candidates = [ budget.blocked_until ]
          if budget.last_request_at.present?
            candidates << budget.last_request_at + configuration.search_pacing_seconds
          end
          earliest = candidates.compact.max

          earliest if earliest&.>(now)
        end
      end

      def payload
        { present: present, resource: resource, limit: limit, remaining: remaining,
          reset_at: Ingestion::Report.timestamp(reset_at),
          observed_at: Ingestion::Report.timestamp(observed_at),
          request_ceiling: request_ceiling, reserve: reserve, spendable: spendable,
          used: used, actor_used: actor_used, repository_used: repository_used,
          available: available,
          blocked_until: Ingestion::Report.timestamp(blocked_until),
          last_request_at: Ingestion::Report.timestamp(last_request_at),
          next_request_earliest_at: Ingestion::Report.timestamp(next_request_earliest_at) }
      end
    end
  end
end
