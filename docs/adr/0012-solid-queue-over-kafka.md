# 12. Solid Queue in a second PostgreSQL database, not Kafka

Date: 2026-07-31

Status: Accepted

## Context

"Ingest events from a feed, persist them, enrich them in the background" is a shape that
invites a broker. Kafka is the reflexive answer, and `IMPLEMENTATION_PLAN.md` §14 asks for
a record of why it was not selected — not because Kafka is a bad technology, but because
choosing it here would have been a decision made by pattern-matching rather than by
arithmetic.

The arithmetic:

- The source is **one polled HTTP endpoint** under an unauthenticated ceiling of 60
  requests per hour per IP. At the default cadence the system issues twelve poll requests
  an hour and reads at most ~100 events per page.
- Peak sustained ingest is therefore on the order of **a few hundred events an hour**,
  bounded by upstream quota rather than by anything downstream.
- Enrichment is bounded by the same 60-request ceiling — around 40 requests an hour after
  the poll allowance and reserve, which §10 states plainly is a *sample* of demand rather
  than coverage of it.

Nothing in that profile is throughput-constrained. The bottleneck is a third party's rate
limit, and no amount of broker capacity moves it.

## Decision

Use Solid Queue, backed by its own PostgreSQL database
(`github_push_ingestor_queue_development`) inside the same container as the business
database (`config/database.yml`).

Three reasons, in order of weight:

1. **A broker would carry no durability the business tables do not already carry.** The
   durability boundary is the committed `push_events` row (ADR 0005), and pending
   enrichment work is not a message — it is the state of a committed entity row
   (`enrichment_status`, `next_retry_at`). `ReconcilePendingEnrichmentsJob` rebuilds the
   work list from those rows every 60 seconds, which is why ADR 0008 can call the enqueue
   a *hint*. Delete every queued job and the system loses nothing: the next tick
   re-derives the same work. A broker would be a second, weaker copy of a record
   PostgreSQL already holds under constraints.
2. **One database is one backup, one restore, one transaction boundary.** The queue lives
   beside the business tables in the same PostgreSQL instance, so a `pg_dump` captures
   both consistently, `docker compose exec db psql` inspects the queue with the same tool
   as everything else, and `enqueue_after_transaction_commit` gives a real ordering
   guarantee between a committed event and the job that reacts to it. With a broker,
   "committed but not enqueued" and "enqueued but not committed" both become states
   someone has to reason about.
3. **A component a reviewer has to run is a component that has to earn its place.**
   `IMPLEMENTATION_PLAN.md` §17 states the target: small enough to understand, complete
   enough to trust. Kafka adds a broker, a coordination layer, its own durability
   configuration, and its own failure modes to a system whose actual hard problem —
   spending 60 requests an hour correctly across two competing consumers — is entirely
   inside PostgreSQL.

Kafka, Redis, and Sidekiq are all named in §2's out-of-scope list for this reason, and
`CLAUDE.md` forbids reintroducing them without first amending the plan.

## Consequences

What this buys:

- `docker compose up --build` starts exactly four containers: `db`, `setup`, `web`,
  `worker`. There is no broker to provision, tune, or explain.
- Queue state is inspectable with SQL, which is what makes the crash-recovery drill in the
  README runnable by hand — truncate `solid_queue_jobs`, restart the worker, and watch
  reconciliation rebuild the work from committed rows.
- The job system inherits PostgreSQL's durability rather than having its own. There is one
  answer to "what survives a crash", not two.

What it costs, stated plainly:

- **Queue throughput is bounded by PostgreSQL.** Solid Queue polls tables; it will not
  match a broker at high message rates. Irrelevant at ~12 polls and ~40 enrichment
  requests an hour, and it would stop being irrelevant the moment an authenticated token
  raised the ceiling to 5,000 requests an hour — that is the scaling point where this
  decision deserves re-examination, and it is named in `docs/DESIGN_BRIEF.md`.
- The queue competes with business queries for the same PostgreSQL instance's connections
  and I/O. Mitigated by the separate database and by `config/queue.yml` keeping its thread
  count inside `RAILS_MAX_THREADS`, but not eliminated.
- There is no fan-out to other consumers, no replay of a durable log, and no
  cross-service event bus. If a second service ever needed this event stream, that is a
  real reason to revisit — the current answer would be to read `push_events`, which works
  for one reader and not for many.

`spec/queue/solid_queue_integration_spec.rb` and `spec/queue/configuration_spec.rb` hold
the queue to its declared configuration, and `spec/recovery/pending_enrichment_recovery_spec.rb`
asserts the property that makes this decision safe: with the queue emptied, committed
entity rows are enough to rebuild the pending work.
