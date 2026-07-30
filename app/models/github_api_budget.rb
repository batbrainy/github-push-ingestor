# The single-row global request ledger (§7, §10). Every outbound live request from
# any process — poller, worker, one-shot — reserves capacity here before execution,
# because the unauthenticated limit is keyed to the outbound IP rather than to any
# one event source.
#
# The reservation logic itself (the allowance formula, transactional debiting,
# per-window bootstrap, and startup validation) is Github::BudgetLedger in PR 4.
# This class is the schema surface only, and no row is seeded here.
class GithubApiBudget < ApplicationRecord
  # Singular by design: the table holds exactly one row, enforced at the schema level
  # by CHECK (id = 1).
  self.table_name = "github_api_budget"

  SINGLETON_ID = 1

  WINDOW_STATUSES = %w[uninitialized active globally_blocked].freeze

  enum :window_status, WINDOW_STATUSES.index_by(&:itself), validate: true

  COUNTERS = %i[
    poll_allowance poll_used
    enrichment_allowance enrichment_used
    actor_share_used repository_share_used
    reserve
  ].freeze

  validates(*COUNTERS, numericality: { greater_than_or_equal_to: 0 })
end
