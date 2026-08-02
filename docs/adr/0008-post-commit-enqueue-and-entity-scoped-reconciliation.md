# 8. Enrichment is enqueued after commit and reconciled from the entity rows

Date: 2026-07-31

Status: Accepted; durable-backlog ordering amended 2026-08-02; staged-batch enrichment amended 2026-08-02

## Context

§2A puts Solid Queue in its own `queue` database inside the same PostgreSQL container —
the separate-database configuration new Rails 8 applications generate. That choice is what
creates this decision: an enqueue cannot join the business transaction, because the two
writes are to different databases. Rails names the boundary
(`enqueue_after_transaction_commit`) but naming it does not answer what happens to work
whose enqueue never ran.

The crash window is real and small: a `push_events` row commits, the process is killed,
and the enrichment the run was about to schedule is gone. §8 says what must be true
anyway — "the event and its stub entities remain durable in PostgreSQL. Pending enrichment
is rediscovered after restart by scanning entity rows — a small, entity-scoped set, not N
event rows per entity."

A second fact shapes the design as much as the first: **enrichment jobs carry no entity
id.** `Github::EnrichmentRunner` enriches one entity per call and chooses it itself,
through §10's fairness policy and a `FOR UPDATE SKIP LOCKED` lease, FIFO by
`created_at ASC, id ASC`. That is
not an accident to route around — an id-addressed job would have to bypass that ordering to
honour its argument, which is precisely how a repository flood starves actors (ADR 0007).
So an enqueue cannot mean "enrich this actor". It can only mean "there may be actor work".

## Decision

1. **The committed entity rows are the durable record of pending work; the enqueue is a
   hint.** `github_actors.enrichment_status` and its partial index
   `index_*_on_enrichment_candidates` already express the predicate exactly. Nothing is
   written to represent pending work a second time.

2. **One dispatch per run, after the lock is released.** `Github::IngestionRunner#call`
   calls `Github::Enrichment::Dispatch` once, only when the run created events, after every
   row of the run has committed, the run row is finalized, and the source advisory lock is
   gone.

3. **`ReconcilePendingEnrichmentsJob` is scheduled every 60 seconds and is the recovery
   mechanism.** It asks the same object the same question, from committed state alone. Work
   whose enqueue was lost — to a crash, to a queue-database failure, to a discarded job —
   is eligible for rediscovery on a later successful scheduled tick, with no cleanup job.
   The schedule is nominal; queueing, worker downtime, or database unavailability can delay
   execution.

4. **At most one job per class per dispatch**, whatever the backlog depth.

5. **No `retry_on` on any job.** The durable retry ladders already exist and are
   coordinated with the ledger: `Github::Ingestion::PollState` for a source,
   `Github::Enrichment::EntityState` for an entity. A later successful scheduled tick
   initiates eligible retry work.

## Consequences

Positive:

- The crash window has no special case. The system's recovery path and its steady-state
  path are the same code, which means the recovery path is exercised on every tick rather
  than only during an incident.
- Operational job-queue depth is bounded by dispatch rather than by entity arrival rate;
  the durable business backlog is intentionally not bounded. One live page
  references ~181 distinct entities; enqueuing per created event would produce ~2,400
  argument-identical cycles an hour against 40 spendable requests, and each surplus cycle
  would run selection and fairness reads only to be told no.
- The queue is never read to answer a question about business state, which keeps
  CLAUDE.md's source-of-truth rule intact: PostgreSQL business tables are the durable
  record, not the queue.

Negative, and accepted:

- Recovery after a lost enqueue is not immediate. The 60-second schedule sets the nominal
  opportunity; queueing and service outages can extend the delay.
- A dispatch that finds work still only *schedules* one cycle per class, so a large backlog
  drains at the reconciler's cadence rather than in a burst. `bin/enrich --limit N` remains
  the operator's handle when a burst is wanted.
- The reconciler runs whether or not anything is pending. Its cost when idle is one indexed
  `EXISTS` per class plus one ledger read, and it logs at debug so an exhausted window does
  not emit a line a minute.

## Alternatives rejected

**Enqueue per created push event.** The natural reading of §8 step 10, and wrong here for a
reason specific to this design: the job carries no entity id, so N enqueues carry exactly
the information one does. The arithmetic above (~2,400 cycles/hour against 40 requests)
makes it a queue full of no-ops, and the dedupe it would then need — Solid Queue's
`limits_concurrency … on_conflict: :discard` — is a mechanism bolted on to undo a decision
rather than to make one.

**Enqueue inside `Github::Ingestion::PageWriter`'s per-envelope transaction.** Closest to
§8's step ordering, and it breaks the property the step exists for: the enqueue would
precede the commit it is supposed to follow.

**Solid Queue concurrency limits keyed by source id** (§9's third multi-poller bullet).
Rejected for PR 8 with a reason, not deferred silently: a `limits_concurrency` semaphore has
a fixed `duration`, so a process crash mid-poll would suppress that source until the
semaphore expired. The session advisory lock this system already holds is released by
PostgreSQL the instant the backend dies. Adopting a weaker, crash-unsafe duplicate of an
existing lock — in the PR whose subject is surviving process crashes — would be a
regression. The source lock, the global request gate and the unique event constraint are
the protections in force; revisit when PR 11's multi-poller tests can measure a gap.

**PR 11 measured it. Verdict: no gap, and the rejection stands.**
`spec/recovery/multi_poller_spec.rb`'s "the gap ADR 0008 asked PR 11 to measure" takes four
observations, on the definition that a gap exists iff sustained contention leaves some
observable cost or incorrectness a source-keyed semaphore would have prevented.

1. Five contended ticks against a held source lock produce no run row, no request, no debit,
   no schedule movement and no event — the four things the semaphore would exist to prevent
   are already zero across a window, not merely across one tick.
2. A contended tick issues **no INSERT, UPDATE or DELETE at all**. A semaphore costs an insert
   and a delete in `solid_queue_semaphores` per acquire, so it would spend writes to prevent
   writes that never happen.
3. The lock frees a killed session in milliseconds, measured against `CLOCK_MONOTONIC`,
   where a fixed-`duration` semaphore must by construction outlast the longest legitimate
   poll. This is the crash-safety argument above, measured rather than asserted.
4. Agreement on the key comes from `Github::Ingestion::SourceProvisioner`, not from any
   concurrency primitive — two first-time processes that each created a row would hold
   semaphores on two different keys and both poll.

The verdict is executable rather than prose: an example asserts that no job under `app/jobs/`
declares `limits_concurrency`, so reversing this decision fails a test and sends the author
back to this section.

Bounded honestly: that measurement covers correctness and local cost. Whether a
`solid_queue_semaphores` round trip is material under N real worker containers is a load
question, and nothing here answers it.

**A dedicated outbox table.** A row per pending enrichment would be a second representation
of a fact the entity row already carries, with its own drift and its own cleanup. §2A calls
this design outbox-*style* precisely because there is no such record.

**Per-source fan-out from the tick.** One job per due source, rather than one job that
iterates them. The global request gate makes outbound concurrency exactly one
application-wide, so the fanned-out jobs would serialize on the same advisory lock while
each held a database connection. Deferred to PR 9, which owns multi-source allocation.

## Amendment (2026-08-02): dispatch enqueues staged cycles; observations commit with the event

Plan Appendix G ([ADR 0013](0013-derivation-first-staged-batch-enrichment.md)) replaces
the per-class `EnrichActorJob`/`EnrichRepositoryJob` with a single argument-less
`EnrichmentCycleJob`: `Github::Enrichment::Dispatch` enqueues at most one cycle when the
dual-ledger admission and claimability checks say work could proceed, and a cycle runs
batch lanes then detail lanes inside its time budget. The decisions here carry over
unweakened — the enqueue is still a hint, the entity rows (now stage-carrying) are still
the durable record, and `ReconcilePendingEnrichmentsJob` still sweeps them every 60
seconds. One addition strengthens the durability boundary: event-source
`enrichment_observations` rows are written **inside** the ingest transaction, so the raw
evidence an entity's derivation rests on commits atomically with the push event itself.

## Related

- ADR 0002 — advisory locks and the request gate (the crash-safety property this decision
  leans on)
- ADR 0004 — the class-aware budget ledger (what bounds enrichment throughput)
- ADR 0005 — repeated execution with duplicate-safe event writes (the narrow event-row and
  entity-activity guarantees under redelivery)
- ADR 0007 — enrichment fairness shares and borrowing (why a job cannot carry an entity id)
- ADR 0013 — derivation-first staged batch enrichment (the staged cycle this dispatch feeds)
