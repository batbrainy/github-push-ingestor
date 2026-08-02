# Live durable-backlog and capacity verification

```text
Probe date:       2026-08-02 (UTC)
Runtime SHA:      cfff765dd24eff44409731ab21a54743cb4a6f01
Run window:       2026-08-02T16:24:25Z → 2026-08-02T16:28:27Z
Docker:           28.3.0
Docker Compose:   2.38.1-desktop.1
API version:      2022-11-28
Authorization:    none sent
GitHub mode:      live
Isolation:        fresh Compose project and fresh PostgreSQL volume; no web or worker
```

## Questions

This probe answers three separate questions:

1. Does the changed application still reach GitHub and enrich real entities?
2. When its enrichment allowance is exhausted, does waiting work remain byte-for-byte
   actionable rather than becoming a terminal budget-skip outcome?
3. Is the default unauthenticated capacity large enough to catch up with the live backlog?

The first two answers are **yes**. The third answer is **no under the traffic observed in
this short sample**.

## Method and safety boundary

The probe used the current branch image and a fresh, explicitly named Compose project:

```text
gpi-durable-live-proof-20260802
```

Only `db`, the one-shot `setup`, `ingest`, and `enrich` services ran. The normal project
database was never attached, and no background worker could make an unplanned request.

To reach an allowance boundary without wasting forty live requests, the isolated process
used this deliberately conservative test configuration:

```text
GITHUB_MODE=live
POLL_INTERVAL_SECONDS=3600
MAX_PAGES_PER_POLL=1
RATE_LIMIT_RESERVE=58
```

Against GitHub's observed limit of 60, the application derived one poll request, one
enrichment request, and a reserve of 58. This is not the production default; it exercises
the same ledger denial path with the smallest safe live request count.

No response bodies, logins, repository names, API URLs, avatar URLs, request IDs, cookies,
or IP addresses are included below. Counts, local row IDs, timestamps, classifications, and
rate-limit fields are sufficient to establish the result.

## Live poll created a real backlog

The first one-shot poll reached `https://api.github.com/events`, and GitHub's response
headers initialized the ledger:

```text
budget.window_initialized
  limit=60  remaining=59  used=1  reserve=58
  poll_allowance=1  enrichment_allowance=1
  reset_at=2026-08-02T17:24:26Z

ingestion.run_completed
  pages_fetched=1  events_received=100  push_events_seen=99
  events_created=99  events_ignored=1  events_failed=0

actor pending=99
repository pending=99
```

One live page therefore created **198 cold entity rows** in this sample.

## A live request exhausted the scaled allowance

The next one-shot enrichment selected the oldest repository and received a real `200`
document from GitHub:

```text
enrichment.completed
  pool=pending  classification=ok  entity_status=complete

actor backlog=99
repository backlog=98
enrichment_used=1  enrichment_allowance=1
remaining=58  reserve=58
```

Exactly 197 rows remained actionable after that successful request.

## The denied cycle changed nothing

Immediately before the next enrichment cycle, all actionable entity-state fields were
hashed in deterministic class/id order:

```text
actionable rows:         197
actionable fingerprint:  f5e9892d16a89d3182474b4b9aa2db4d
oldest actor:            pending, enrichment_attempts=0
oldest repository:       pending, enrichment_attempts=0
```

The next real-mode command stopped at the ledger and reported:

```text
Enrichment deferred — class_exhausted
Entities enriched: 0
Entities failed:   0
Cycles deferred:   1
```

The same database queries afterward returned:

```text
actionable rows:         197
actionable fingerprint:  f5e9892d16a89d3182474b4b9aa2db4d
oldest actor:            pending, enrichment_attempts=0
oldest repository:       pending, enrichment_attempts=0
enrichment_used:         1 of 1
remaining:               58
```

That equality is the central proof: quota denial made no entity-state write, consumed no
additional ledger attempt, and discarded no row.

## Controlled capacity reopening resumed the same oldest row

Waiting for a naturally elapsed GitHub hour was intentionally not represented as necessary
for this bounded probe. Instead, after the documented poll floor had passed, only the
isolated ledger's `reset_at` was moved one second into the past. A second real GitHub poll
then exercised the production rollover path and reinitialized the ledger from new
authoritative response headers:

```text
budget.window_rolled
budget.window_initialized
  limit=60  remaining=55  used=5
  reset_at=2026-08-02T17:18:11Z
```

The live response reported `used=5` while the deliberately reset local ledger recorded only
its new poll. Four requests were therefore absent from the new local counters: two were this
probe's known first poll and first enrichment, which the controlled local rollover erased,
and two show other activity from the same outbound IP during the natural GitHub window. The
deliberately extreme reserve of 58 therefore blocked enrichment, as designed. For the final
resumption check, the isolated row's reserve was lowered to 54, opening exactly one safe slot
while leaving the one-request enrichment allowance unchanged.

Before that slot opened, repository row `id=2` was the oldest waiting repository:

```text
id=2  status=pending  enrichment_attempts=0
created_at=2026-08-02T16:24:26.68435Z
```

The next enrichment used a real GitHub response and changed that same row to:

```text
id=2  status=complete  fetched_at=2026-08-02T16:28:27.667939Z
enrichment_used=1 of 1  remaining=54  reserve=54
```

This is a **controlled rollover/capacity-boundary test**, not evidence that a natural GitHub
hour elapsed. It shows that an old row survives denial and is selected again when the
production ledger makes capacity available. The automated test described below covers a
clock-driven later window deterministically.

At the end of the live run:

```text
skipped_budget rows: 0
skipped_at columns:  0
```

## Capacity finding: durability does not imply catch-up

The first live page added 198 entity lookups. At the default unauthenticated enrichment
allowance of 40 request attempts per window, that page alone requires:

```text
198 / 40 = 4.95 full hourly allowances
```

In other words, it needs capacity from five quota windows. That is not a 4.95-hour wall-clock
lower bound: work may arrive near a reset and each window's capacity can be spent in a
burst. It is also the optimistic request count—no new events, no retries, no redirects, and
every request settling one entity.

The controlled second poll ran about 193 seconds later and added another 94 actors and 96
repositories: **190 new cold entity rows**. This is a short pressure sample, not a sustained
arrival-rate measurement. It nevertheless confirms the order of magnitude behind the
documented limitation. If default five-minute polls continue to receive pages with roughly
190 cold entities, twelve polls add about 2,280 entity lookups per hour while at most 40
attempts work the backlog. Under the optimistic assumption that every attempt settles one
row, the durable entity backlog then grows by roughly 2,240 rows per hour; retries and
redirects make the completion side smaller.

In plain terms: this correction turns dropped work into a real waiting list. It does not
make the service desk faster. The waiting list shrinks only during periods when new unique
work arrives more slowly than enrichment completes.

GitHub authentication is explicitly outside this project's permitted scope. The service
must remain inside GitHub's documented 60-request/hour unauthenticated limit:
[REST API rate limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api).
No scheduler, queue, or additional local worker can turn that fixed upstream allowance into
more requests.

The current automatic dispatcher can already offer roughly 144 entity cycles/hour, which
is deliberately above the 40-request enrichment allowance. A faster or self-refilling pump
would therefore spend the same 40 requests earlier in the window and then stop; it would not
increase service capacity.

Under the simultaneous requirements of five-minute polling, full per-entity API enrichment,
no discarded backlog work, and no authentication, bounded catch-up is not achievable when
unique arrivals remain above 40/hour. The valid no-token choices are explicit tradeoffs:

1. keep the present polling cadence and retain every enrichment request durably, accepting
   that backlog size and age can grow without bound under sustained pressure; or
2. apply polling backpressure while backlog exists, reassign unused polling capacity to
   enrichment, and accept substantially less event capture.

With the 8-request safety reserve and polling suspended, at most 52 unauthenticated requests
per hour could work enrichment. A backpressure implementation would also have to let one
enrichment request bootstrap each later quota window; the current ledger permits only a poll
to initialize a new window, and that poll would add more work. With that correction, even
the first observed page's 198 cold rows would consume about 3.8 full hourly enrichment
allowances, with no intervening polls, retries, or redirects. As above, allowance-hours are
not a wall-clock lower bound because work can arrive near a reset. A strict bounded-backlog
mode would therefore poll only after the previous page's backlog had drained, materially
worsening the public feed sampling rate. Redefining the required enrichment fields to use
only event-envelope data would be a third product-scope choice, not an implementation
optimization: actor names and repository descriptions and languages are absent from those
envelopes.

The honest operational response is to expose arrival rate, completion rate, backlog slope,
and oldest age, then make the polling-versus-backlog priority explicit. There is no hidden
no-token implementation that preserves all four requirements and guarantees catch-up.

## Automated coverage matching this behavior

Automated tests intentionally block all external network access; a deterministic test must
not depend on today's public event feed. The live transport proof above is therefore kept
as dated evidence, while the state-machine guarantee is exercised offline.

The correction adds an integration scenario with 23 actors and 23 repositories—46 durable
rows, larger than the default 40-request enrichment allowance. It uses the real runner,
fairness selector, request gate, budget ledger, claim, parser, and entity-state writer, with
Faraday intercepted by WebMock:

1. the first window completes exactly the oldest 20 actors and oldest 20 repositories;
2. call 41 is `class_exhausted` and sends no HTTP request;
3. all six remaining rows are still `pending`, with zero attempts, no retry timestamp, and
   no error;
4. a later window is opened through another poll/header reconciliation;
5. the remaining oldest three actors and three repositories complete FIFO; and
6. all 46 rows finish `complete`.

An additional selector example explicitly mirrors FIFO ordering for two repository rows.
Migration, constraint, retry, recovery, backlog-metric, status, worker-routing, and
concurrency specs continue to cover their respective boundaries.

## What this probe does not show

- A natural GitHub rate-limit window did not elapse; rollover was controlled and is labeled
  as such above.
- Two polls on one host and one date do not establish a sustained arrival average.
- The one-request live allowance is a test configuration, not the production default.
- No authenticated request was made or proposed; authentication is outside the permitted
  project scope.
- The probe proves durability and honest capacity accounting. It does not claim that the
  present unauthenticated deployment can catch up; the live data shows the opposite.
