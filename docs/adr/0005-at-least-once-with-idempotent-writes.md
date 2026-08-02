# 5. Repeated execution with duplicate-safe event writes

Date: 2026-07-30

Status: Accepted; guarantee wording clarified 2026-07-31 and 2026-08-02

## Context

Fetching a third-party HTTP feed and persisting its events cannot be one atomic act.
Repetition and loss are both possible at different boundaries:

- Consecutive `/events` polls intentionally overlap when an event remains in GitHub's
  sliding feed. Processing never stops at the first known event.
- A crash between an HTTP response and the database commit loses that attempt. The event
  can be recovered by a later poll only if it is still present in the sliding feed.
- Solid Queue may run a job again when a worker dies before acknowledgement, including
  after the job's business write committed.

The feed does not promise that this service observes every event before the window
advances. The queue and polling paths also cannot provide exactly-once execution across an
HTTP service, a queue database, and the business database.

## Decision

Accept repeated execution and enforce two narrow ingestion invariants at the database
boundary:

1. A duplicate observation of a GitHub event cannot create a second `push_events` row.
2. A duplicate observation cannot register new entity activity.

Those invariants are implemented by
`ON CONFLICT (github_event_id) DO NOTHING RETURNING id` and by applying entity activity
updates only when `RETURNING` yields a newly inserted row. A duplicate may still refresh
permitted identity fields under Section 7's merge rules, but never an enrichment payload.

Other writes have intentionally different repetition semantics:

- Stub entities upsert on `github_id` and may refresh identity fields.
- Quarantine rows upsert on a canonical `payload_fingerprint` and increment
  `occurrence_count` for every observation.
- Each ingestion attempt may create or update an `ingestion_runs` summary.
- Request reservations, job executions, logs, and other operational effects may repeat.

The durability boundary is the committed `push_events` row (Section 8), not the HTTP
response, queue entry, or run summary. Transactions are per envelope rather than per page,
so one malformed envelope cannot roll back valid neighbors. Quarantine writes are isolated
from the event transaction so a later event failure cannot erase the observed malformed
payload.

## Consequences

What this buys:

- Re-polling or manually re-running ingestion cannot duplicate an accepted event row or
  falsely register new entity activity from the same event ID.
- Committed events survive process and container restarts without a separate dedup table
  or distributed transaction.
- Committed entity state is sufficient for the reconciler to rediscover pending enrichment
  after a cross-database enqueue gap.

What it does not buy:

- This is not exactly-once execution. A job, HTTP request, run record, quarantine
  observation, budget debit, or log entry may occur more than once.
- An event lost before commit is not guaranteed to reappear; recovery depends on GitHub
  retaining it in a later sliding-feed response.
- Duplicate work still consumes CPU, and another poll or HTTP retry consumes quota before
  uniqueness can reject an event row.
- `events_quarantined` counts observations rather than unique rows: replaying the same bad
  payload increments `occurrence_count` even though its row remains unique.
- The first quarantine classification is retained, so classification must remain a pure,
  precedence-ordered function of the payload.

The suite tests the stated boundaries: fixture replay leaves four `push_events` rows,
increments the three quarantine occurrence counters, and does not register duplicate entity
activity. A separate recovery test
shows a delivered enrichment job may execute again without creating another entity row;
that scenario does not widen the ingestion guarantees above.
