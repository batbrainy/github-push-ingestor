# 7. Enrichment fairness shares are enforced in the ledger and borrowed on the caller's word

Date: 2026-07-30

Status: Accepted; durable-backlog policy amended 2026-08-02; staged-batch enrichment amended 2026-08-02

## Context

§10's demand arithmetic settles the shape of enrichment before any code is written. One
observed live page of `/events` held ~92–95 push events referencing ~89 distinct actors and
~92 distinct repositories: 181 cold entity requests per page, ~2,172 an hour at the default
cadence if every poll contained new identities, against 40 available. This is a pressure
scenario rather than a measured deduplicated arrival rate. The 40 attempts are a reserved
service budget for a durable backlog, and the allocation must make progress across both
entity classes.

Left to a simple queue it allocates badly. Repository candidates alone exceed the whole
hourly allowance, so a repo-first policy — or any policy ordering purely by recency across
a mixed pool — starves actor enrichment to zero indefinitely, which fails Story 3 outright.
§10 therefore fixes a split with explicit rounding and one escape hatch:

```text
actor_guarantee      = floor(enrichment_allowance × ACTOR_ENRICHMENT_SHARE)
repository_guarantee = enrichment_allowance − actor_guarantee

Borrowing: a class may borrow the other's unused capacity only when the
other class has no CURRENTLY CLAIMABLE backlog candidate (not merely no rows).
```

Two facts make this awkward to place. The guarantee is arithmetic over
`github_api_budget`, which ADR 0004 gave a single writer with a deliberately narrow
locking discipline. The borrow condition is a question about `github_actors` and
`github_repositories` — two tables that writer must not touch, because reaching for them
from inside the most contended row lock in the application would invert the locking order.

## Decision

1. **The share is enforced inside `Github::BudgetLedger#reserve!`**, under the same
   `SELECT … FOR UPDATE` as the debit, as a fifth denial reason `:share_exhausted`. ADR
   0004 rejected a second writer of `github_api_budget` outright, and a fairness check
   outside the row lock would be advisory rather than enforcement.

2. **The borrow is a parameter, not a query.** `reserve!(request_class, now:, borrow:)`
   takes the caller's assertion that the other class has no currently claimable backlog candidate.
   `Github::Enrichment::Fairness` establishes it; the ledger enforces the arithmetic that
   follows from it. It defaults to `false`, so every existing caller and every careless one
   gets enforcement.

3. **The flag rides on `Github::Request`** rather than on a `RequestExecutor` argument.
   `#redirected_to` uses `with` and a retry reuses the request unchanged, so the
   authorization survives both — and re-reserving a borrowed request under the guarantee
   cap mid-chain would deny after the first hop had already been spent.

4. **A borrowing reservation is capped at `enrichment_allowance`, not at
   `guarantee + the other class's unused capacity`.** The two authorize exactly the same
   set. `actor_share_used + repository_share_used == enrichment_used` is an invariant of
   the three debit statements, and the class guard is evaluated first, so a borrower is
   already limited to `enrichment_allowance − other_share_used` — which is what §10's
   phrasing computes. Taking the simpler of two equivalent caps makes the borrowed SQL
   guard degenerate into the class check, which is what "only the class cap binds" should
   look like on the page. Stated here because a reader checking the code against §10's
   wording will otherwise think they diverge.

5. **The guarantees are derived at read time and never stored.** ADR 0006 made the same
   call for class blocking, and the reason carries: a stored guarantee goes stale the
   moment `Allowances#clamped` lowers `enrichment_allowance` at a window rollover. They are
   computed from the row's *stored* `enrichment_allowance`, never from a fresh derivation,
   so the guarantee and the class cap it sits inside always come from one number.

6. **The share is a denial, not a deferral.** `:share_exhausted` writes no global block —
   `RateLimitPolicy#reserve_breach` globalizes only `:reserve_reached` — and it is absent
   from `Github::EnrichmentSchedule`. §9's `effective_enrichment_time` names
   `enrichment_used >= enrichment_allowance`, the class cap, and admitting the share would
   have two consequences: there is no honest instant to name (a share is relieved either by
   the window rolling *or* by the other class running out of claimable backlog candidates, and the
   second has no timestamp), and it would make borrowing unreachable, because the schedule
   would answer "not due" before the runner ever computed a borrow.

7. **`ACTOR_ENRICHMENT_SHARE` is validated over the closed interval `[0.0, 1.0]`** and
   parsed with `Rational`, not `Float`. A zero guarantee is reachable by arithmetic
   whatever validation allows — an allowance of 1 floors to 0/1 at the pinned share, and
   `#clamped` can yield 0/0 — and §10 relieves it through borrowing rather than through the
   split, so `0.0` means "repository first, actors during the quiet periods", a policy
   rather than a fault. What has no meaning is the complement: a negative share puts the
   repository guarantee *above* the class allowance, and a share above one mirrors it.
   `Rational` because the value is multiplied by an integer allowance and floored, and
   IEEE-754 loses that by one at reachable inputs — `(100 * 0.29).floor` is 28, not 29.

## Consequences

- Fairness is real rather than advisory: a repository flood is refused at 20 requests with
  the actor guarantee untouched, and the refusal costs no quota.
- Both classes demonstrably enrich within their guarantees (§16), and `bin/enrich` prints
  per-class usage and backlog progress so an operator can see whether the queue is draining.
- **The borrow fact is stale by construction.** A poll can persist a new candidate between
  the eligibility query and the debit. The exposure is bounded to one request — the runner
  enriches at most one entity per invocation — it self-corrects on the next call, and it can
  never exceed the class cap, which the ledger checks first.
- **A caller passing `borrow: true` unconditionally would defeat fairness, and the ledger
  cannot detect it.** That is the price of decision 2. Three things bound it: the default
  is `false`; the decision lives in exactly one method of
  `Github::Enrichment::Fairness`, which a spec pins; and a borrow that actually mattered is
  logged at DEBUG with its class.
- **One state reports "due" and is still refused.** On a fresh install or immediately after
  a rollover, all three of §9's components are nil while `reserve!` refuses with
  `:window_uninitialized`. Keeping §9's formula literal was preferred to adding a fourth
  component; the state ends at the next poll, so it is bounded by one poll cadence, and
  `Github::Enrichment::Fairness` asks the same question first so the runner reports the
  honest reason without taking the request gate to learn it.
- Retuning `ACTOR_ENRICHMENT_SHARE` takes effect on the next reservation, mid-window, since
  the guarantee is derived. A class already past its new, lower guarantee is simply refused
  until the window rolls; nothing is refunded, consistent with failures-stay-spent.

## Alternatives considered

- **A stored `actor_guarantee` column.** Rejected for ADR 0006's reason: it goes stale
  across a rollover, and it would put a second number beside the one that produces it.
- **A second writer of `github_api_budget` holding the fairness logic.** Rejected by ADR
  0004 before this PR existed — it would duplicate `assert_committable!`, the uncached
  `SELECT … FOR UPDATE`, and the manual `lock_version` bump.
- **The ledger querying the entity tables to establish the borrow itself.** Rejected: it
  puts the most contended row lock in the application above two more, and it would make the
  ledger depend on the enrichment domain rather than on request classes.
- **`guarantee + other_unused` as the borrow cap.** Rejected as equivalent but more moving
  parts — it needs a `max(…, 0)`, a read of the other class's counter, and a guard that
  cannot be read off the statement.
- **The share as a component of `effective_enrichment_time`.** Rejected by decision 6: it
  would make borrowing unreachable.
- **`Float` coercion for the share.** Rejected as wrong by one at inputs an operator can
  type. The failure is precision rather than soundness — the sum invariant survives, because
  the repository guarantee is a subtraction — but it silently loses an attempt off the
  number on the page.

## Amendment (2026-07-31): the refresh pool follows the same two steps

The 2026-08-02 amendment below further restricts *when* this pool may run; the allocation
arithmetic here still applies after the durable never-enriched backlog is empty.

This ADR decided how the pending pool allocates and left the refresh pool's *selection
order* unstated, and the shipped `#refresh_choice` did not follow it: it took the first
refreshable class in `EntityType.all` order — always actor — and set `borrow` from whether
that class happened to be past its guarantee. Its borrow test also read the pending
eligibility map, so the other class's stale rows were invisible to it. The result was the
starvation this ADR exists to prevent, reproduced one pool down: actor could spend the whole
enrichment allowance on refreshes while repository's untouched guarantee and eligible stale
rows were never selected.

`#refresh_choice` now performs the same two steps as `#pending_choice` — prefer a class with
`room_within_guarantee?`, then borrow only from a class with nothing to refresh — over an
eligibility map built from the refresh pool. `CandidateSelector#pending_available?` is
unchanged and stays pending-only; decision 3's reasoning about the prioritization ladder is
about the *pending* borrow test and still holds.

See [ADR 0010](0010-secondary-limit-escalation-and-refresh-pool-fairness.md) for the full
context, the rejected "refreshes never borrow" reading of §10:898, and the
`borrowed_refresh` choice reason.

## Amendment (2026-08-02): pending work is durable FIFO backlog

Quota scarcity delays enrichment; it does not make a never-enriched entity expendable.
Entity rows remain the durable work record until enrichment reaches a success or a genuine
entity-specific failure outcome. Exhausting the hourly allowance merely defers the row to a
later rate-limit window. The pending pool is ordered by immutable, non-null
`created_at ASC, id ASC`; `first_seen_at` can be null and is not a safe queue key. Sustained
arrivals therefore cannot keep older work from being attempted.

The default hourly ledger reserves 12 attempts for polling, 40 for the enrichment class,
and 8 as a safety reserve. Within the 40, durable backlog has priority; actors and
repositories receive 20-attempt guarantees and may borrow only when the other class has no
currently claimable backlog candidate. Refresh work is lower priority than the entire
never-enriched pool: a selection that observes either class has never-enriched work does not
choose a refresh. Once that pool is observed empty, refreshes use the same guarantee and
borrowing arithmetic described above.

That observation and the later debit are not one database snapshot. Ingestion can commit a
new candidate between them, so one already-selected refresh can cross the boundary. The
exposure is at most one request because a runner invocation handles one entity, and the next
selection self-corrects. This cannot erase backlog state or exceed the enrichment cap.

This policy deliberately does not promise a bounded completion time. If unique entities
arrive faster than 40 attempts per hour can serve them, backlog size and oldest pending age
will grow. That pressure is reported directly; work is never converted into a terminal
budget outcome merely because the quota window ended.

## Amendment (2026-08-02): share fairness is now detail-lane only; search lanes use weights

Plan Appendix G ([ADR 0013](0013-derivation-first-staged-batch-enrichment.md)) makes
Search batches the normal enrichment path, so this ADR's share arithmetic —
`floor(enrichment_allowance × ACTOR_ENRICHMENT_SHARE)`, borrowing on the caller's word,
`:share_exhausted` as a denial — now governs only the bounded core **detail-fallback**
lane, whose allowance is `CORE_DETAIL_FALLBACK_ALLOWANCE` (default 4, so the guarantees
default to 2/2). The batch lanes are balanced differently: a weighted rotation
(`ACTOR_ENRICHMENT_WEIGHT` / `REPOSITORY_ENRICHMENT_WEIGHT`, defaults 1/1) over whole
Search requests, with a lane that has nothing claimable yielding its slot — batch
capacity is per-request rather than per-entity, so a per-entity share would misdescribe
it. The deleted `Enrichment::Fairness` class's decisions survive in `BatchClaim`
(claimability), `CycleRunner`'s lane schedule (rotation and borrowed slots), and the
ledger's unchanged share enforcement for detail requests.
