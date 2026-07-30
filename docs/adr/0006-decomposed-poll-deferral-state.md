# 6. Poll deferral state is decomposed, never collapsed into one timestamp

Date: 2026-07-30

Status: Accepted

## Context

V1 of the plan expressed "when may this source be polled again?" as a single
`next_poll_at`. Three review rounds took it apart: Appendix B item 2 decomposed the
scheduling constraints, Appendix C item 2 removed `reset_at` from routine scheduling and
added a blocking timestamp, and Appendix D item 2 split global blocking from class
blocking. ADR 0004 built the ledger those rounds specified and stopped exactly here, saying
so: deriving `poll_class_blocked_until` for scheduling, handling secondary limits, and
setting the global block were left to the PR that would schedule polls.

A collapsed timestamp fails in three concrete ways, and each one is a behaviour rather
than an aesthetic complaint:

1. **`--force` cannot tell which part it may bypass.** §9 lets the one-shot ignore the
   application's own cadence so a reviewer can see a poll happen on demand, while still
   obeying GitHub's `X-Poll-Interval` floor. With one timestamp the flag either bypasses
   everything — violating the floor and risking the budget — or bypasses nothing, and the
   demo does not work.
2. **A routine `X-RateLimit-Reset` defers every poll to the top of the hour.** Every
   successful response carries one. Folded into the same field the cadence lives in, a
   healthy `200` at 14:00 reporting a 15:00 reset collapses twelve polls an hour into one,
   and nothing in the logs explains it.
3. **One blocking timestamp makes the two request classes stop each other.** Enrichment
   spending its forty attempts would stop polling, and polling spending its twelve would
   stop enrichment — the contradiction Appendix D item 2 names outright.

## Decision

1. **`effective_poll_time` is the maximum of five independent components**, three on
   `event_sources` (`cadence_due_at`, `poll_floor_until`, `retry_not_before_at`) and two
   from the ledger (`global_blocked_until`, and a derived `poll_class_blocked_until`).
   `Github::PollSchedule` holds them as a value with no database of its own. **`nil` means
   due now** — every component is nil on a clean checkout, so that is the ordinary case.
   No component is ever written back into another.

2. **`next_poll_at` is a cache of the answer and never an input.** It is written after each
   decision and read only by logs, the state summary, and PR 10's `/status`. Reading it to
   decide would re-introduce the collapsed timestamp through the back door: it goes stale
   the moment a block clears.

3. **`--force` removes exactly one term, plus the stored ETag.** `PollSchedule::FORCEABLE`
   is that claim in one place. `force` is never passed to the page loop, the executor, the
   ledger, the rate-limit policy, or the poll-state writer, so the other four components
   stay binding by construction; `SourceLock` is acquired before `force` is read at all;
   and `BudgetLedger#reserve!` knows nothing about it, which is a second, independent
   guarantee that a forced run cannot overspend.

4. **`global_blocked_until` stores only §10's three truly-global conditions** — primary
   exhaustion, the reserve being reached, and a secondary limit. `Github::RateLimitPolicy`
   decides the instant from the response that justified it; `BudgetLedger#block_globally!`
   records it, under the same row lock, `assert_committable!` guard and manual
   `lock_version` bump every other statement against that row uses. The write only ever
   moves a block later.

5. **Class blocking is derived at read time and never stored.** `poll_used >=
   poll_allowance ? reset_at : nil`, on `GithubApiBudget`, with a bounded fallback when
   `reset_at` is unknown. Derivation cannot go stale across a rollover, and it keeps §10's
   guarantee that one class exhausting its allowance never stops the other.

6. **`reset_at` stays informational.** It reaches scheduling only through terms already
   gated by an exhaustion predicate — it answers *until when*, never *whether*.

7. **Secondary limits are global even though they arrive on one source's request.** They
   are IP-scoped and can arise on an enrichment request, which has no source row to defer.
   The source's own `retry_not_before_at` is set as well, and that is not redundant:
   rollover clears the global block at the window boundary while the source's component
   survives it.

8. **Pagination is bounded by the budget, never by recognition.** The walk follows
   `rel="next"` until the page cap, a denied reservation, an absent Link, or an empty page
   — and deliberately **not** when it sees an event it already has. §9 gives the reason:
   documented latency is 30 s to 6 h, so a delayed event can surface later beside an
   already-seen one. Every fetched page is processed in full and `github_event_id`
   uniqueness absorbs the duplicates. The ETag is scoped to the canonical first-page
   request and is a bandwidth and correctness measure, never a quota saver — the dated
   probe in
   [`docs/evidence/2026-07-30-unauthenticated-304-quota-probe.md`](../evidence/2026-07-30-unauthenticated-304-quota-probe.md)
   is why.

9. **A run row exists iff the process tried to reach GitHub.** A poll the schedule turned
   away writes no `ingestion_runs` row and no source state.

## Consequences

**What this buys.** `--force` is demonstrable and safe at the same time, and the two
properties are provable separately. Class isolation is observable end to end. An expired
block needs no cleanup pass, because deriving from timestamps is self-recovering — the
ledger's own comment notes that a `globally_blocked` label whose instant had passed would
otherwise be a state with no exit. The one-shot names an honest instant for every deferral
but two, with no allowlist to maintain. A poll that is not due costs no request, no run
row, and no quota.

**What it costs, stated plainly.**

- Five components is more state than one, and every write path has to be explicit about
  which of them it owns. `Github::Ingestion::PollState`'s write matrix is that explicitness
  made concrete, and it is not small.
- The cached `next_poll_at` can be stale. Nothing reads it for a decision, but a reviewer
  looking at the column has to know that.
- A derived class block is recomputed on every scheduling decision. Cheap against one row,
  but not free, and not indexed.
- `reserve_reached` is a ledger denial that sits *outside* the formula, so the one-shot has
  one special case rather than none. Making the reserve a scheduling component was
  considered and rejected: it reflects GitHub's `remaining` rather than this application's
  plan, and a co-tenant's window rolling can clear it at any moment, so it has no stable
  instant to schedule against.
- A pre-flight deferral writes no run row, so `ingestion_runs` is a history of *attempts*
  and not of scheduler ticks. Skipped cycles are countable from the logs only. This is
  deliberate — under PR 8's recurring task the alternative is dozens of zero-count rows an
  hour diluting every counter in the table — but it is a real limitation.
- `global_blocked_until` is cleared as a side effect of window rollover, so
  `budget.global_block_cleared` records the write rather than the moment the block stopped
  biting. There is no event for "the clock passed it", because nothing happens then.
- None of this prevents another client behind the same public IP from exhausting the
  window, exactly as ADR 0004 already states. The ledger coordinates this application only.

## Alternatives considered

- **One `next_poll_at` as the input.** Rejected for the three failures in Context.
- **A stored `poll_class_blocked_until` column.** Rejected by §10, and asserted against in
  `spec/models/github_api_budget_spec.rb`: a stored value goes stale across a rollover, and
  the counters it would duplicate are already on the row.
- **A second class writing `github_api_budget`.** Rejected: it would duplicate
  `assert_committable!`, the uncached `SELECT … FOR UPDATE`, and the manual `lock_version`
  bump, putting two files on the most safety-critical row in the application.
- **Checking the cadence before taking the source lock.** Rejected: two processes would
  both read a stale `cadence_due_at`, both decide they were due, serialize on the lock, and
  poll back to back — defeating the guarantee the lock exists to provide.
- **Opening an `ingestion_runs` row for a not-due attempt.** Rejected; see Consequences.
- **Reusing `RetryPolicy#backoff_seconds` for source backoff.** Rejected: that is
  in-request retry, bounded by `MAX_HTTP_RETRIES` with a one-second base and no ceiling.
  Source backoff counts polls against a five-minute cadence and must cap, so a dead source
  is still retried hourly.
- **A `polling` status on `event_sources`.** Rejected: the source advisory lock already
  answers "is a poll in flight", authoritatively and crash-safely, which a status column is
  not.
