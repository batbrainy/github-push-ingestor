# 10. Secondary-limit escalation and refresh-pool fairness

Date: 2026-07-31

Status: Accepted; durable-backlog refresh priority amended 2026-08-02

## Context

`IMPLEMENTATION_PLAN.md` §4's Extension A lists ten child capabilities. Nine shipped
across PRs 4, 6, 7 and 9. Reading the merged code against the plan's own wording, rather
than against the issue checklists, found two of them incomplete in ways their tests did not
catch — both because the test set up a single-class world in which the defect is invisible.

**Item 8 — "Handle secondary rate limits globally (`Retry-After` →
`global_blocked_until`); add exponential backoff with jitter."** §10 words the fallback as
"set `global_blocked_until` from `Retry-After` (or ≥ 1 minute with exponential backoff when
the header is absent)". `Github::RateLimitPolicy#fallback_instant` called
`@backoff.retry_at(1, now:)` with a literal `1`. `Github::PollBackoff#delay_for` computes
`exponent = [attempt, 1].max - 1`, so attempt `1` fixes `exponent = 0` and `base = 60` on
every call. The ≥ 1 minute floor and the jitter were both real; the exponential was not.
Nothing else compensated — `Github::Ingestion::PollState` routes a `:secondary_limited`
outcome to `secondary_retry`, which deliberately does not increment `consecutive_failures`,
so the source-scoped ladder never advanced either. An IP GitHub was actively throttling was
re-probed every ~60–75 seconds for as long as the throttling lasted.

**Item 9 — "Implement enrichment fairness shares (floor/remainder rounding) with
eligibility-aware borrowing."** §10:898 scopes refreshes "within each class's share".
`Github::Enrichment::Fairness#refresh_choice` selected
`requested.find { refresh_available? }` — first in `EntityType.all` order, always actor —
with no preference for a class still inside its guarantee, unlike `#pending_choice`, which
looks for `room_within_guarantee?` before it considers borrowing. Its borrow condition also
read the *pending* eligibility map, so the other class's stale refresh candidates were
invisible to it. With guarantees at 20/20, `actor_share_used: 20`, `repository_share_used:
0`, no pending work anywhere and stale rows in both classes, actor borrowed its way from 20
to 40 while repository's untouched 20-request guarantee and eligible refresh work were never
selected. That is the class starvation the split exists to prevent (§10: "a naive repo-first
policy would starve actor enrichment to zero indefinitely"), reproduced one pool down with
the order reversed.

## Decision

### The secondary-limit streak is a counter on the budget singleton

`github_api_budget.consecutive_secondary_limits`, `NOT NULL DEFAULT 0`, with its own named
check constraint. `Github::RateLimitPolicy#secondary_limit` reads it and passes
`streak + 1` as `PollBackoff`'s attempt, producing 60 → 120 → 240 → … capped at
`MAX_BLOCK_SECONDS` (3600) by the existing ceilings in both classes. Jitter is unchanged and
still additive-only, so the floor §10 states numerically is never undercut.

Four boundaries make this the smallest correct change:

- **It escalates only the header-absent path.** A server-supplied `Retry-After` is still
  obeyed as given within `honoured`'s clamp, which is exactly how §10 words the alternative.
- **Only `:secondary_rate_limit` advances it.** A primary exhaustion and a reserve breach
  are conditions of the budget window, not evidence that GitHub is throttling this IP.
  `#primary_limit` passes a literal attempt of `1` for the same reason — a quota provably at
  zero is relieved by the window rolling, not by waiting longer each time.
- **It survives window rollover.** §10 calls secondary limits IP-scoped, which is a
  different scope from the primary window `ROLL_WINDOW_SQL` resets. Zeroing the streak at
  the boundary would hand a persistently throttled IP a fresh 60-second block every hour.
- **One clean response ends it.** `#apply!` calls
  `BudgetLedger#clear_secondary_limit_streak!` for any live request that completed —
  including a `304`, which is a request GitHub answered and charged for and therefore the
  same evidence a `200` carries. A timeout or a 5xx produced no verdict about throttling, so
  it neither escalates nor clears.

**The policy reads the count; the ledger writes it.** The increment is a bind on `BLOCK_SQL`
rather than a second statement, so it happens under the same `SELECT … FOR UPDATE` that
writes the block it feeds. The read in the policy is therefore stale by construction:
`#apply!` runs after the request gate is released, so two responses can read the same count.
That is accepted rather than removed. The consequence is an under-escalated block and never
an over-escalated one, `BLOCK_SQL`'s `GREATEST` means the loser's shorter instant cannot
shorten the winner's, and computing the instant inside the ledger would collapse the split
[ADR 0004](0004-class-aware-budget-ledger.md) draws between deciding and recording.

`#clear_secondary_limit_streak!` guards in its `WHERE` (`AND consecutive_secondary_limits
> 0`) rather than reading first, so the overwhelmingly common case — every successful
request on a service that has never been throttled — is one statement that matches no row
and takes no lock. Zero affected rows is the expected outcome, so it deliberately does not
go through the `LedgerInvariantViolation` check `#debit!` applies to the same condition.

### The refresh pool runs only after the durable backlog is observed empty

Before considering any refresh, fairness checks both entity tables for every
candidate-status row (`pending` or `retryable_failure`) without applying the due-time
predicate. A backed-off row and a row carrying an active lease are still durable
never-enriched work, so either blocks the entire refresh pool at that selection decision.
This gives backlog priority within the 40-request enrichment allowance.

Only after that durable backlog is empty does `#refresh_choice` mirror the per-class
allocation arithmetic: build a claimability map over stale refresh rows, prefer a class
with `room_within_guarantee?`, and only then borrow from a class that has nothing to
refresh. A borrowed refresh reports `borrowed_refresh`, mirroring `borrowed_pending`.

The emptiness read and request debit are deliberately not serialized against ingestion.
A poll can commit a new candidate between them, allowing the one refresh already selected
to proceed. Since one runner invocation issues at most one entity request, the exposure is
bounded to one request; the next decision observes the row and closes the refresh pool. The
ledger cap remains authoritative and the durable row is never discarded.

## Consequences

- A persistently throttled IP now backs off to an hour rather than re-probing every minute,
  which is the behaviour §10 specified and the one least likely to escalate GitHub's
  throttling further.
- One additional row read per secondary-limit response, and one guarded `UPDATE` per
  successful live request that matches no row in the normal case.
- The refresh pool can no longer starve a class. Total enrichment spend is unchanged — the
  ledger's cap was always the bound, and this is a fairness fix rather than an overspend fix.
- A refresh TTL is an earliest eligible time rather than a completion deadline. Sustained
  never-enriched backlog can postpone refresh indefinitely, which is preferable to spending
  reserved backlog capacity on already-enriched rows.
- `Choice::REASONS` gains `borrowed_refresh`. The only consumer of `Choice#reason` is
  `Github::EnrichmentRunner`'s deferral log, which reads it on the not-chosen path only.

## Rejected alternatives

**Escalate by multiplying an in-force block instead of counting.** No migration, but it can
only escalate while a block is still in the future — and the case §10 legislates for is the
repeat limit that arrives *after* the previous block expired, which is precisely when this
approach does nothing.

**Read `Retry-After`'s HTTP-date form as unparseable, as before.** RFC 9110 permits both
forms and §10 lists the header among those to process without qualifying which.
`Github::RateLimitSnapshot` now normalizes both to a delta against its own `observed_at`;
leaving the date form unread silently collapsed a server-supplied "wait 45 minutes" into the
60-second fallback, and obeying an instruction far shorter than the one given is the
response most likely to provoke further throttling. A date already in the past yields a
non-positive delta, which `#fallback_instant` already treats exactly as an absent header.

**Forbid borrowing in the refresh pool outright**, on the strictest reading of §10:898's
"within each class's share". Rejected: a class whose guarantee rounds to zero
(`ACTOR_ENRICHMENT_SHARE` at `0.0` or `1.0`) could then never refresh at all, and it would
leave capacity idle whenever the other class has no stale rows — while §10:812's borrowing
rule is stated generally rather than scoped to the pending pool. Borrowing remains valid
after the durable never-enriched backlog is empty.
