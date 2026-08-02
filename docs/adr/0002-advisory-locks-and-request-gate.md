# 2. Session advisory locks for source ownership and the global request gate

Date: 2026-07-30

Status: Accepted

## Context

Two different things need mutual exclusion, and neither can be held by a database
transaction.

Source ownership. `IMPLEMENTATION_PLAN.md` §9 requires that multiple poller or
worker containers never poll the same event source concurrently. A polling operation
spans several HTTP round trips (up to `MAX_PAGES_PER_POLL` requests plus retries), and
a transaction must never be held open across network I/O.

Outbound serialisation. §2A and §10 require at most one live GitHub request in
flight across the poller, the worker, and the one-shot. Without it, two processes
reserve against the same rate-limit window concurrently and the ledger's accounting
stops meaning anything. GitHub also recommends making requests serially.

V1 claimed source ownership with a `FOR UPDATE SKIP LOCKED` row claim. Appendix C item 1
rejected it: a row lock ends at transaction end, so it cannot own an HTTP operation, and
`SKIP LOCKED` never waits, so the one-shot could not honour §9's contention contract.
Appendix D item 1 then separated the two locks entirely: enrichment requests belong to
no event source, so routing them through a source lock was wrong.

## Decision

Both are PostgreSQL session-level advisory locks, namespaced in the two-int32 form:
`(SOURCE_LOCK, event_source_id)` and `(REQUEST_GATE, 1)`. Never
`pg_advisory_xact_lock`.

Namespaces are literals, `0x47504901` and `0x47504902`, where `0x475049` is ASCII
"GPI". They are not a hash of a seed string, so `SELECT * FROM pg_locks WHERE locktype =
'advisory'` is readable during an incident without running Ruby to decode it, and a
changed seed cannot silently change lock identity. An `event_sources.id` outside int32
raises rather than being reduced modulo, because aliasing two sources onto one key would
serialise them against each other forever with nothing able to detect it.

Connections are leased with `connection_pool#with_connection`, never
`checkout`/`checkin`, and a lock is a lexical block scope with its `ensure` *inside* that
block. Nothing stores a connection or a lock token in an ivar or a thread-local.

The two acquisition strategies differ deliberately. `SourceLock` uses
`pg_try_advisory_lock`: once for the poller, in a bounded retry loop to
`SOURCE_LOCK_WAIT_SECONDS` for the one-shot, which is the mechanism §2A and §9 pin.
`RequestGate` uses blocking `pg_advisory_lock` under `SET LOCAL lock_timeout`.

Release re-asserts the session. The backend PID is captured at acquisition, and the
unlock is conditional on it inside the statement.

The lock-order invariant is enforced at runtime. `Github::LockOrder` tracks held keys
per execution context; taking a source lock while the gate is held raises, and so does a
nested acquisition of either lock.

## Consequences

What this buys:

- Operation-wide ownership that survives an HTTP round trip, released automatically when
  the session dies, which is what makes `docker kill` safe. (Verifying that
  release-on-death behaviour is PR 8's half of the work; this ADR covers acquisition.)
- The gate gets PostgreSQL's own FIFO wait queue in one round trip, and a bounded wait
  that surfaces as a typed `ActiveRecord::LockWaitTimeout`. A `pg_try_advisory_lock`
  poll loop was rejected because `try` does not queue: under real contention (worker,
  poller, and a reviewer's one-shot all live) it degrades into a lottery that can starve
  a waiter indefinitely, and it costs a round trip per iteration. An *unbounded* blocking
  acquire was rejected for a different reason: it has no failing outcome to assert, so a
  broken gate spec would hang CI rather than fail it.
- `SET LOCAL` cannot strand a `lock_timeout` on a pooled connection: the GUC is scoped to
  the transaction and reverts on commit, and there is no `RESET` to forget in an `ensure`.
  The session advisory lock deliberately survives that commit. That is the defining
  property of a session lock, and the reason `pg_advisory_xact_lock` is not used.
- An invariant stated three times in the plan and previously guaranteed only by code
  structure is now a red unit test. The realistic future mistake is precise: someone adds
  "enrich this source's owner" inside a gated block, and without the assertion it
  manifests as a two-container hang with nothing in the logs.
- Advisory locks are re-entrant within a session, so a nested acquisition *succeeds*. The
  re-entrancy guard turns that from a silently doubled in-flight request into a raise.

What it costs, stated plainly:

- Nothing releases a session advisory lock implicitly. Every acquisition depends on
  its `ensure`. Releasing the connection while the lock is still held is the worst
  failure available here: the next context to check that connection out acquires the
  "same" lock re-entrantly, `pg_locks` shows one lock, and two workers believe they own
  it. The block-only API is what prevents it, and the rule is written in the code.
- The lock-order registry is per execution context rather than per connection. That is
  exact only because this design gives each context exactly one connection; if a future
  path ever held two, the marker becomes advisory rather than exact.
- A gate wait bound of 45 seconds is an operational default the plan does not pin. It is
  a code constant rather than an environment variable, derived from the longest possible
  legitimate hold (5s connect + 15s read, since retries re-acquire rather than extend).
- Under RSpec's transactional fixtures the gate's `SET LOCAL` runs inside a savepoint and
  therefore persists to the end of the example rather than to the end of the acquisition.
  Harmless, since it only bounds lock waits, but noted so nobody "fixes" it.

Contention is tested against a genuinely separate PostgreSQL session opened outside the
pool, never a thread: while transactional fixtures have the pool pinned,
`ConnectionPool#checkout` returns the pinned connection to every thread, so a second
thread shares the first thread's session and a thread-based contention example would pass
even if `RequestGate.hold` were an empty method. An `after` hook fails any example that
leaks a lock, because `checkin` expires the lease without resetting the connection.
