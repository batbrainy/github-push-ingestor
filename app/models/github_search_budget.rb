class GithubSearchBudget < ApplicationRecord
  self.table_name = "github_search_budget"

  SINGLETON_ID = 1

  validates :request_ceiling, numericality: { only_integer: true, greater_than: 0 }
  validates :reserve, :used, :actor_used, :repository_used,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  def available
    local = [ request_ceiling - reserve - used, 0 ].max
    return local if remaining.nil?

    [ local, remaining - reserve ].min.clamp(0, local)
  end

  def to_log
    {
      resource: resource, limit: limit, remaining: remaining, reset_at: reset_at&.utc&.iso8601,
      observed_at: observed_at&.utc&.iso8601, request_ceiling: request_ceiling,
      reserve: reserve, used: used, actor_used: actor_used, repository_used: repository_used,
      available: available, blocked_until: blocked_until&.utc&.iso8601,
      last_request_at: last_request_at&.utc&.iso8601
    }
  end
end
