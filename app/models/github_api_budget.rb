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

  # §10's second derivation, the mirror of the one above:
  #
  #     enrichment_class_blocked_until = enrichment_used >= enrichment_allowance ? reset_at : nil
  #
  # The fallback is load-bearing here for the same reason and one more.
  # Allowances#clamped yields enrichment_allowance = 0 whenever the observed limit leaves
  # nothing after the reserve and polling, and both a fresh install and every window
  # rollover leave reset_at NULL. The plan's literal ternary then reports "not blocked"
  # for a class that provably cannot spend, and PR 8's enrichment job re-attempts every
  # tick for the rest of the window, taking the global request gate each time to be told
  # no.
  #
  # One *poll* cadence, and not an enrichment-specific knob, because of what the unknown
  # actually is: reset_at is NULL precisely when the window has not been initialized, and
  # §7 says only a poll can initialize it. "After the next poll could plausibly have
  # happened" is therefore the honest instant, and that is POLL_INTERVAL_SECONDS.
  #
  # Derived from the class cap, never from actor_share_used or repository_share_used.
  # §9's formula names enrichment_used, and the reasoning is that a share exhaustion is a
  # denial rather than a deferral: it is relieved either by the window rolling *or* by the
  # other class running out of eligible candidates, and the second has no instant to name.
  # Deferring on it would also make §10's borrowing unreachable — Github::EnrichmentSchedule
  # would report "not due" before the runner ever computed a borrow.
  def enrichment_class_blocked_until(now:, cadence_seconds: Github.configuration.poll_interval_seconds)
    return nil if enrichment_used < enrichment_allowance

    reset_at || now + cadence_seconds
  end

  # One canonical rendering of the row for §11's structured stream, in the shape every
  # other value here already uses (Github::Allowances, Github::RateLimitSnapshot,
  # Github::PollSchedule, Github::RateLimitPolicy::Decision all answer #to_log).
  #
  # It exists so the budget lines PR 9 adds cannot describe the same row with different
  # field names than the lines that already exist. Timestamps are ISO-8601 UTC because a
  # log stream is read across timezones; nils are kept rather than compacted, since
  # "remaining is unknown" and "remaining was not reported" are different facts to an
  # operator reading one line.
  def to_log
    { window_status: window_status, resource: resource, limit: limit, remaining: remaining,
      reserve: reserve, reset_at: reset_at&.utc&.iso8601,
      global_blocked_until: global_blocked_until&.utc&.iso8601,
      poll_used: poll_used, poll_allowance: poll_allowance,
      enrichment_used: enrichment_used, enrichment_allowance: enrichment_allowance,
      actor_share_used: actor_share_used, repository_share_used: repository_share_used }
  end
end
