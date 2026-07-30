# 5. At-least-once processing with idempotent writes

Date: 2026-07-30

Status: Accepted

## Context

Polling a third-party feed over HTTP, from a process that can be killed at any moment,
gives no way to make "fetch a page" and "persist its events" one atomic act. Three
mechanisms in this system each guarantee *at least* one delivery and none guarantees
exactly one:

- GitHub's `/events` feed is a sliding window with a documented 30s–6h latency, and
  `IMPLEMENTATION_PLAN.md` §9 processes every fetched page in full with no
  stop-on-known-event, so consecutive polls overlap by design.
- A crash between the HTTP response and the commit loses the work, and the same events
  reappear on the next poll (§8, "Crash before commit").
- From PR 8, Solid Queue re-runs a job whose worker died before acknowledgement (§8,
  "Worker crash after enrichment commit but before acknowledgement").

Two responses were available. Chase exactly-once execution — a distributed-transaction
or dedup-ledger design across an HTTP client, a queue in a second database, and the
business tables. Or accept repetition in *execution* and make it invisible in
*outcomes*.

## Decision

Accept at-least-once execution and make every write idempotent, so the durable outcome
is the same however many times an event is processed:

```text
At-least-once execution
+ Idempotent writes
+ Unique constraints
= Effectively-once persisted outcomes
```

Four mechanisms implement it, and each is a database guarantee rather than an
application convention:

1. **`push_events`** inserts with `ON CONFLICT (github_event_id) DO NOTHING RETURNING id`.
   A re-polled event is a no-op, and an accepted raw event is never mutated by a re-poll.
2. **Stub entities** upsert with `ON CONFLICT (github_id) DO UPDATE` under §7's merge
   rules, which refresh identity fields and never touch an enrichment payload.
3. **`quarantined_events`** upserts on `payload_fingerprint` — SHA-256 of compact UTF-8
   JSON with recursively sorted keys — incrementing `occurrence_count`. The fingerprint
   is the sole unique key, because a malformed event may be malformed precisely because
   it lacks an event ID.
4. **Entity activity updates are gated on `RETURNING` producing a row.** A duplicate
   replay may refresh identity fields but registers no activity and, from PR 7, can
   never reactivate an entity that a budget skip had terminated.

The durability boundary is the committed `push_events` row (§8). Not the HTTP response,
not the queue, not the `ingestion_runs` row — that last one is a summary artifact, and a
process killed mid-page leaves it in `running` with zeroed counters, which is the honest
signal rather than a bug.

Transactions are per envelope, not per page. PostgreSQL aborts an entire transaction on
any failed statement, so a page-wide transaction would let one malformed envelope
discard the events already reported as persisted beside it — exactly what §16's
"malformed data … does not terminate the batch" forbids. Quarantine writes stand outside
any transaction, so a quarantine record can never be discarded by a later failure.

## Consequences

What this buys:

- **Re-running ingestion is always safe.** `docker compose run --rm ingest` can be
  invoked at any frequency: duplicates are absorbed by uniqueness, replays never register
  false activity, and a deferral is exit 0 rather than a failure — so an operator never
  has to reason about whether a re-run is safe before typing it.
- Crash recovery needs no reconciliation of partial writes. Whatever committed is
  correct; whatever did not reappears on the next overlapping poll.
- Restart safety costs no extra infrastructure: no dedup table, no distributed
  transaction, no coordination between the queue database and the business tables.

What it costs, stated plainly:

- **This is not exactly-once execution, and the system must never claim it is** (§8,
  §16, `CLAUDE.md`). Side effects that are not idempotent writes — a log line, a metric,
  an outbound notification — can and will repeat.
- Duplicate work is spent work. A re-polled page re-runs classification for events
  already stored, and its request already debited the budget ledger.
- `events_quarantined` counts observations, not rows: the same malformed payload seen
  twice reports 1 and 1 while `occurrence_count` climbs to 2. Consistent with
  `duplicates_skipped`, which also counts observations.
- The first classification of a quarantined payload is permanent — `error_code` is never
  refreshed on replay — which is why classification is a pure, order-stable function of
  the payload with a declared precedence order rather than whatever check happened to run
  first.

The suite asserts the outcome rather than the mechanism: ingesting the same fixture page
twice produces four push events, three quarantine rows with `occurrence_count` at two,
unchanged entity activity, and a planted `skipped_budget` entity still skipped.
