# 4. A class-aware budget ledger with one derived allowance formula

Date: 2026-07-30

Status: Accepted; staged-batch enrichment amended 2026-08-02

## Context

The unauthenticated GitHub limit is 60 requests an hour, keyed to the outbound IP
rather than to any event source, and non-search REST endpoints share the `core` resource,
so `/events`, actor retrieval, and repository retrieval all compete for one budget
(`IMPLEMENTATION_PLAN.md` §10). Two dated unauthenticated probes showed `x-ratelimit-used`
incrementing across a `304`, so this application budgets every request including
conditional ones. (§10 makes re-running that probe a required validation gate; the
first-party transcript is
[`docs/evidence/2026-07-30-unauthenticated-304-quota-probe.md`](../evidence/2026-07-30-unauthenticated-304-quota-probe.md).)

V1 had mechanisms but no numbers. Appendix A item 2 recorded the consequence: polling at
the observed `X-Poll-Interval` of 60 seconds is 60 requests an hour, the entire budget,
which starves the enrichment Story 3 requires.

Appendix B item 1 then made the ledger class-aware. §7 states why a simpler design fails:
"A plain `remaining > reserve` check is not enforcement: without class counters,
enrichment could legally consume 52 requests at the top of the hour and leave the twelve
scheduled polls nothing."

## Decision

One authoritative formula, derived rather than configured:

```text
poll_attempt_allowance = ceil(3600 / POLL_INTERVAL_SECONDS)
                         x MAX_PAGES_PER_POLL x ENABLED_LIVE_SOURCE_COUNT
enrichment_allowance   = effective_limit - RATE_LIMIT_RESERVE - poll_attempt_allowance
```

Startup validation rejects any configuration where `poll_attempt_allowance + reserve`
reaches the limit. `effective_limit` is the last observed `x-ratelimit-limit`, falling
back to the documented unauthenticated 60, a constant rather than a knob.

The ledger enforces; the policy decides. `reserve!` refuses when the window is
globally blocked, when an enrichment class asks before the window is initialized, when
`remaining` has reached the reserve, or when the class allowance is spent. It reads
`global_blocked_until` but never writes it; deriving `poll_class_blocked_until` for
scheduling, handling secondary limits, and setting the global block are PR 6's.

Pessimistic `SELECT … FOR UPDATE` on the single row, not optimistic `lock_version`
retry, though `lock_version` is still incremented by hand in the raw SQL.

The bootstrap is the first real poll. An uninitialized window grants a poll and counts
it; enrichment is refused until a response has initialized the window from authoritative
headers.

Reconciliation is monotonic within a window (`remaining = LEAST(local, observed)`)
and verifies `x-ratelimit-resource` before any arithmetic.

Failures stay spent. There is no `credit!`, `refund!`, or `release!`.

## Consequences

What this buys:

- Class isolation is real: enrichment exhausting its forty attempts never stops polling,
  and polling exhausting its twelve never stops enrichment.
- A misconfiguration stops the container at boot instead of polling into an
  over-commitment, and validation touches no database, so it is safe before migrations.
- The bootstrap costs nothing. An extra quota-discovery request would waste one of sixty,
  and per-window rather than per-install matters because an IP co-tenant may spend
  immediately after each reset. 60 remaining is never assumed.
- `remaining <= reserve` is the only denial reflecting GitHub's view rather than our own
  counters, which is what stops a co-tenant burning the shared IP while our class
  counters happily grant requests into a remaining of zero.
- PR 7 adds fairness predicates over `actor_share_used` and `repository_share_used` that
  this PR already records accurately, so there is no back-fill.
- A stale in-memory record still raises `StaleObjectError` rather than clobbering
  counters, because the raw debit bumps `lock_version` itself.

What it costs, stated plainly:

- Every outbound attempt is spent, including ones that fail. A 500 retry or a forced
  one-shot consumes poll allowance and can reduce the number of completed scheduled polls
  that hour. These are request-*attempt* allowances, not guaranteed polls.
- The ledger coordinates this application only. Other software behind the same public
  IP can consume capacity outside it. Response headers remain the source of truth and the
  ledger converges to them, but it cannot prevent a co-tenant from exhausting the window.
- A response from a different rate-limit resource is logged and skipped rather than
  applied or raised. Applying it would import another bucket's numbers and reset window,
  producing denials indistinguishable from real exhaustion; raising would let one stray
  URL crash-loop the poller against §10's "do not crash-loop".
- Allowances are re-derived at window rollover and initialization, not mid-window. An
  operator who changes a knob waits up to an hour for it to take effect, which is the
  price of keeping the change atomic with the counter reset.
- Two PostgreSQL NULL behaviours are load-bearing and had to be defeated explicitly.
  `GREATEST` *ignores* NULL, so `GREATEST(NULL - 1, 0)` is 0. Decrementing an
  un-bootstrapped `remaining` that way creates a permanent reserve breach that denies
  every request including the bootstrap poll that could have refreshed it. The same
  deadlock appears if rollover carries a stale `remaining` forward. Both are covered by
  specs verified to fail when the guard is removed.
- Under RSpec's transactional fixtures nothing commits, so "the debit is durable before
  the request" is proved three separate ways rather than one: the ledger has no refund
  path, the joinability guard that prevents `reserve!` being joined into a rollback-able
  transaction is unit-tested, and one non-transactional example observes the committed
  row from a second session.

`GITHUB_RATE_LIMIT_DEFAULT` was considered and rejected. 60 is an external GitHub fact
rather than a policy choice, it is only the starting point for the very first window, and
the startup-validation rejection path is exercisable by lowering `POLL_INTERVAL_SECONDS`
instead. Deriving `ENABLED_LIVE_SOURCE_COUNT` from `event_sources` at runtime is PR 9's
"dynamic multi-source allocation validation"; doing it at boot would reintroduce the
database dependency that keeps validation safe to run before migrations.

## Amendment (2026-08-02): the core ledger is now one of two resource ledgers

Plan Appendix G ([ADR 0013](0013-derivation-first-staged-batch-enrichment.md)) moves
normal-path enrichment onto GitHub's per-minute search resource, accounted by its own
singleton ledger (`Github::SearchBudgetLedger` over `github_search_budget`). This ledger's
mechanics (transactional reservation, failures-stay-spent, monotonic reconciliation,
resource verification, per-window bootstrap) are unchanged, but its
`enrichment_allowance`/`enrichment_used` pair is redefined: it now budgets the bounded
payload-URL detail-fallback lane (`CORE_DETAIL_FALLBACK_ALLOWANCE`, default 40/hour) rather
than the remainder formula, and feasibility becomes
`poll + reserve + detail_fallback ≤ limit`, with the remainder deliberately unspent.
The resource-mismatch skip above now cuts both ways: this ledger ignores `search` headers,
and the search ledger ignores `core` headers.
