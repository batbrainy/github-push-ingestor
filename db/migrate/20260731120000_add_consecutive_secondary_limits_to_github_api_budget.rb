# §10: "On any secondary-limit response: set global_blocked_until from Retry-After (or
# >= 1 minute with exponential backoff when the header is absent)."
#
# The exponential half needs a count of consecutive secondary limits, and that count has
# to outlive the process that observed them: the poller, the worker, and the one-shot all
# issue live requests against one IP-scoped limit, so a streak observed by the worker must
# escalate the block the poller then honours. It therefore lives on the same singleton row
# as global_blocked_until rather than in memory.
#
# Deliberately *not* reset by ROLL_WINDOW_SQL. A secondary limit is IP-scoped and has no
# relationship to the primary rate-limit window (§10), so a streak that spans a window
# boundary is still a streak. Github::RateLimitPolicy clears it on the first live request
# that completes without one.
class AddConsecutiveSecondaryLimitsToGithubApiBudget < ActiveRecord::Migration[8.1]
  def change
    add_column :github_api_budget, :consecutive_secondary_limits, :integer,
               null: false, default: 0

    # A separate named constraint rather than a rewrite of
    # github_api_budget_counters_nonnegative. That one is a single expression covering the
    # reservation counters; folding an unrelated counter into it would mean dropping and
    # recreating a constraint every future column touches, and the failure message would
    # then name seven columns that are fine.
    add_check_constraint :github_api_budget,
                         "consecutive_secondary_limits >= 0",
                         name: "github_api_budget_secondary_limits_nonnegative"
  end
end
