# The single-row global request ledger (§7, §10). Every outbound live request from
# any process — poller, worker, one-shot — reserves capacity here before execution,
# because the unauthenticated limit is keyed to the outbound IP rather than to any
# one event source.
#
# The reservation logic itself (the allowance formula, transactional debiting,
# per-window bootstrap, and startup validation) is Github::BudgetLedger. This class is
# the schema surface plus one derived reader, and no row is seeded here.
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

  # §10: "Class blocking is derived from counters, never stored globally."
  #
  #     poll_class_blocked_until = poll_used >= poll_allowance ? reset_at : nil
  #
  # It lives here rather than in Github::BudgetLedger because it is a projection of three
  # columns of this row, not a decision — the ledger's division of labour is that it
  # enforces and records while the policy decides, and reading three of its own columns
  # is neither.
  #
  # The fallback is load-bearing rather than defensive. Allowances#clamped yields
  # poll_allowance = 0 whenever the observed limit is at or below the reserve, and both a
  # fresh install and every window rollover leave reset_at NULL. The plan's literal
  # ternary then returns nil — "not blocked" — for a class that provably cannot spend,
  # and a poller re-attempts every tick forever. "Blocked, but we do not know until when"
  # has to resolve to a bounded instant, so it resolves to one cadence away.
  #
  # This is also the only place reset_at reaches scheduling, and it does so behind an
  # exhaustion predicate. §9's "reset_at is informational; it never participates in
  # scheduling directly" is about the other direction: a routine X-RateLimit-Reset on a
  # healthy 200 must never defer the next poll to the top of the hour.
  def poll_class_blocked_until(now:, cadence_seconds: Github.configuration.poll_interval_seconds)
    return nil if poll_used < poll_allowance

    reset_at || now + cadence_seconds
  end
end
