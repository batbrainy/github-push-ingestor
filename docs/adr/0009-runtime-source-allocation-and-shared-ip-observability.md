# 9. Runtime source allocation, a clamp that cannot strand the ledger, and shared-IP observability

Date: 2026-07-31

Status: Accepted

## Context

`IMPLEMENTATION_PLAN.md` §13 gives PR 9 the advanced tier of the budget system:
dynamic multi-source allocation validation, shared-IP reconciliation edge cases, ledger
bootstrap edge cases, stress and concurrency tests, budget observability, and advanced
configuration validation. The core (the ledger, the formula, the gate, scheduling and
fairness) shipped in PRs 4 to 7 and, per the descope ladder, is never cut.

[ADR 0004](0004-class-aware-budget-ledger.md) left one item here by name:

> Deriving `ENABLED_LIVE_SOURCE_COUNT` from `event_sources` at runtime is PR 9's "dynamic
> multi-source allocation validation"; doing it at boot would reintroduce the database
> dependency that keeps validation safe to run before migrations.

Reading the shipped code for that change surfaced two more facts worth deciding about
rather than leaving implicit. First, `Allowances#clamped` could derive a poll allowance of
zero, which is unrecoverable. Second, §7's honest limitation, "the ledger coordinates this
application only", had no runtime evidence behind it: `x-ratelimit-used` was parsed by
`Github::RateLimitSnapshot` and read by nothing.

## Decision

The allowance formula's source count comes from `event_sources`, at window
initialization and rollover only. `Github::SourceAllocation` counts rows matching
`EventSource.pollable` (enabled, `idle`, and of the current mode's `source_type`) and
`Github::BudgetLedger` passes that count into `Allowances.derive`. Zero rows means a fresh
install, where `Github::Ingestion::SourceProvisioner` has not run yet, and the configured
value answers instead. A mismatch between the two logs `budget.source_allocation_drift` at
WARN, naming both counts and both poll allowances.

Three boundaries make this safe:

- Boot validation still reads the environment and no database. `Configuration#validate!`
  is unchanged, so `bin/rails db:prepare`, `rails runner` and CI's schema load still work
  before any table exists. ADR 0004 required this and PR 9 preserves it.
- `#bootstrap!` is not a derivation point. It runs ahead of every reservation, and the
  row it inserts is `uninitialized`: the first response overwrites all three allowances
  before enrichment may spend anything. Putting a query there would cost one per
  reservation to write values nothing reads.
- The count runs inside the ledger's row lock, and cannot deadlock there. `count` takes
  only `ACCESS SHARE` on `event_sources`, which does not conflict with the
  `SHARE ROW EXCLUSIVE` the provisioner holds; and no session can hold an `event_sources`
  lock and then reach for the ledger row, because `assert_committable!` refuses to reserve
  inside an application transaction at all.

`Allowances#clamped` floors the poll allowance at one. An observed
`x-ratelimit-limit` at or below `RATE_LIMIT_RESERVE` leaves nothing spendable, and the plain
minimum produced `poll_allowance = 0`, which denies every poll `:class_allowance_exhausted`
forever. Nothing recovers from it: only a poll can observe a new limit, and rollover
re-derives from the stored one, which can now never change. One guaranteed attempt is the
bootstrap poll §7 already depends on, and it is not an overspend, because
`remaining <= reserve` denies it on the ledger's own terms as soon as `remaining` is known.

Co-tenant consumption is reported, never applied. On reconciliation the ledger compares
GitHub's `x-ratelimit-used` against `poll_used + enrichment_used`; a positive difference is
capacity someone else behind the same IP spent. It is logged at DEBUG as
`budget.co_tenant_usage`, and raised to INFO as `budget.co_tenant_pressure` at the one
moment it becomes actionable: the observed `remaining` reaching the reserve, which is about
to deny every class for the rest of the window.

Three more silences became lines. `budget.allowances_clamped` (WARN) when the runtime
derivation was infeasible and clamping bit; `budget.window_reset_in_past` (WARN) when a
response's reset instant has already passed; `config.budget_resolved` (INFO) and
`config.amplification` (WARN) at boot.

`config.amplification` warns; it does not refuse. The allowance formula counts one
attempt per page, while §10 makes every retry and every redirect hop its own reservation,
so one logical poll can cost `(MAX_HTTP_RETRIES + 1) x (MAX_REDIRECTS + 1) x
MAX_PAGES_PER_POLL` attempts, 9 of 12 at the pinned defaults and 36 at retries and redirects
of 5.

The threaded stress specs run as their own process, under `spec/stress`, excluded from
the default `rspec` run by `.rspec` and executed by a second invocation in both the compose
`test` service and CI.

## Consequences

What this buys:

- The formula stops depending on an operator remembering to update a variable when they add
  or disable an event source, and the two numbers disagreeing is now a log line instead of a
  silent under-provision.
- A starved observed limit degrades instead of stranding the ledger permanently. The failure
  mode was reachable from any `x-ratelimit-limit` at or below 8 and had no exit at all.
- §7's shared-IP caveat is observable rather than merely documented. An operator seeing a
  window die at 40 requests can tell "someone else spent them" from "we spent them", which
  the class counters alone cannot answer.
- The budget-ledger row lock is now proved rather than asserted: removing `.lock` from
  `reserve!` fails six of the ten stress examples. The single-threaded specs pass without it.

What it costs, stated plainly:

- The derived count is a fact about the poller's own database, not about the IP. Another
  container behind the same address still spends the same sixty requests an hour, and no
  count of `event_sources` can see it. This narrows one failure mode; it does not make the
  ledger authoritative.
- The count is read at two moments per window, so a source added mid-window changes
  nothing until the next rollover, up to an hour. That is ADR 0004's existing trade
  (allowances change atomically with the counter reset) applied to a new input, not a new
  one.
- A drift warning fires on every derivation while the drift lasts, twice an hour at
  most, which is why it is not rate-limited further.
- The clamp floor grants one poll attempt in a window the reserve already forbids. It is
  one request an hour, spent only while `remaining` is unknown, and it is the price of the
  state being recoverable at all.
- Divergence is derived, not stored. §7 fixes `github_api_budget`'s column list and an
  `observed_used` column is not on it, so the comparison is made per reconciliation and
  logged rather than persisted. A consequence is that "first divergence in this window" is
  not knowable, so the INFO line keys on the reserve threshold instead.
- `budget.window_reset_in_past` reports a condition it does not fix. Under clock skew
  the window initializes and then rolls back to `uninitialized` on the next reservation, so
  enrichment, ineligible until a window is initialized, gets nothing for as long as the
  skew lasts. Refusing to initialize was considered and rejected: it starves enrichment
  identically while removing the only signal that names the cause. Polling is unaffected
  either way, because an uninitialized window is precisely the state §7 grants a poll in.
- The stress specs cost a second `rspec` process. They open genuine concurrent
  PostgreSQL sessions, and `spec/support/advisory_lock_helpers.rb` documents the assumption
  that breaks: with transactional fixtures the pool is pinned, so every thread shares one
  session and the two advisory locks are re-entrant. Growing the pool changes that for the
  whole run, not just for the group that did it. Cleaning up afterwards left the suite green
  at most seeds and deadlocking at some, which is not a property worth shipping.
