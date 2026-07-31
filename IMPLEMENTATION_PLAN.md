# GitHub Push Event Ingestion Service — Implementation Plan

> **This plan was finalized through four pre-implementation review rounds**: an adversarial multi-lens design review with live probes of the unauthenticated GitHub API (**Appendix A**), an independent validation pass against official GitHub, PostgreSQL, and Rails/Solid Queue documentation (**Appendix B**), an implementation-readiness re-check that corrected locking, scheduling, Compose, and PR-ordering defects (**Appendix C**), and a freeze-readiness pass that corrected lock scoping, class-level blocking, bootstrap, restart, and reactivation semantics (**Appendix D**). The initial plan (V1) and the full revision trail are preserved in Git history; the appendices record what changed and why. The one section added during revision is numbered **2A** to keep the original numbering stable.
>
> File locations: this plan lives at the repository root. `DESIGN_BRIEF.md` and the ADRs live under `docs/`.

## 1. Purpose

Build a production-minded, locally runnable Ruby on Rails service that polls GitHub’s Public Events API, processes `PushEvent` records, retains raw and structured data in PostgreSQL, enriches actors and repositories, and remains recoverable across application and worker crashes.

The implementation will prioritize:

- Correctness and durability
- Clear separation of responsibilities
- Duplicate-safe accepted-event persistence and explicit restart recovery
- Predictable GitHub API usage driven by an **explicit, formula-derived, class-aware request budget**
- Simple local operation through Docker Compose
- Observable system behavior
- Focused tests for important failure modes
- Small, understandable pull requests

The delivered implementation will satisfy the required public-events source while preserving an extensible event-source adapter for future GitHub Events API endpoints. The fixture event source and fixture transport (Section 12) are second concrete implementations of their respective seams, shipped in this submission.

## 2. Scope

### In scope

- Ruby on Rails in API-only mode
- PostgreSQL as the system of record
- Docker and Docker Compose (profiles, one-shot setup service, restart policies)
- GitHub Public Events API integration
- `PushEvent` filtering and processing
- Raw event payload retention (semantic retention via `jsonb` — see Section 7)
- Structured push-event fields
- Actor and repository enrichment (**budget-bounded, best-effort sampling with per-class fairness** — see Section 10)
- Duplicate-safe `push_events` persistence
- Pagination via the `Link` response header
- ETag and `304 Not Modified` handling (bandwidth/correctness measure, scoped to the canonical first-page request — see Sections 9–10)
- `X-Poll-Interval` support (treated as a server-imposed floor, never the cadence)
- **Persisted, class-aware global request-budget ledger derived from one validated formula, with per-window bootstrap**
- **Global live-request gate (serial outbound concurrency of one, via session advisory lock)**
- **Crash-safe source ownership (session advisory locks, auto-released on session death)**
- Enrichment URL validation (SSRF boundary — see Section 10)
- Bounded retries and deferred retries
- PostgreSQL-backed asynchronous jobs (Solid Queue)
- Recovery of pending work after crashes (including Docker restart policies)
- Durable quarantine of malformed events (fingerprint-keyed, occurrence-counted)
- Structured stdout/stderr logging with level control
- Liveness/readiness health endpoints, status, and inspection endpoints
- Deterministic fixture event source and fixture transport covering polling **and** enrichment, failing closed
- Unit, integration, and failure-path tests
- README and 1–2 page design brief
- GitHub Issues, Project tracking, and focused pull requests
- GitHub Actions CI

### Intentionally out of scope

- Kafka
- Redis and Sidekiq
- Kubernetes
- Prometheus and Grafana
- Elasticsearch
- React or another frontend
- GitHub authentication
- Private repository ingestion
- Complete event capture — not guaranteed by the bounded, delayed Events polling API (see Section 10)
- Complete enrichment coverage — not sustainable under the observed global-feed demand and the unauthenticated 60-request hourly budget (see Section 10)
- Event processors beyond `PushEvent`
- Object storage (Extension C — deliberately not attempted; rationale in the design brief)
- Production cloud deployment
- Multi-region processing
- Long-term analytics dashboards

These may be discussed as future extensions where relevant.

## 2A. Stack Decisions (new in V2)

Pinned before any code is written so no implementation PR stalls on an open choice:

| Decision | Choice | Why |
|---|---|---|
| Framework | **Rails 8.1 API-only** (current release 8.1.3; exact patch locked in `Gemfile.lock`) | Assignment preference; Solid Queue is configured as the default Active Job backend in new Rails 8 applications. Verified current at docs review time |
| Ruby | **Ruby 3.4.10**, pinned exactly in `.ruby-version`, the Dockerfile, and CI | Current maintained Ruby line with a longer support runway (3.3 is already in security-maintenance); compatible with Rails 8.1.3 (requires ≥ 3.2). 3.4.10 verified current (released 2026-06-30) |
| Job backend | **Solid Queue** | Rails default; PostgreSQL-backed (no Redis); recurring tasks drive polling; `FOR UPDATE SKIP LOCKED` job claiming (appropriate for claiming short DB-backed job records). Runs in its own `queue` database inside the same Postgres container — the separate-database configuration new Rails apps generate for production (Solid Queue also supports running in the main database; this plan deliberately uses the separate-database configuration, which the outbox-style recovery assumes) |
| Enqueue semantics | **Post-commit enqueue with durable work-state reconciliation** (outbox-style recovery) | The separate-database configuration used here rules out same-transaction enqueue; Solid Queue documents `enqueue_after_transaction_commit` for exactly this boundary. Business tables are the durable source of pending work; the reconciler is the sweep (ADR in design brief). Precise term: there is no dedicated outbox record, so this is *outbox-style*, not a literal transactional outbox |
| Source ownership | **PostgreSQL session-level advisory lock**, namespaced `(SOURCE_LOCK, event_source_id)` (two-int32 key form), held across the complete **polling** operation on a retained connection, released in an `ensure` block. The poller attempts once and exits if unavailable; the one-shot retries `pg_try_advisory_lock` for up to `SOURCE_LOCK_WAIT_SECONDS` (30). Hard process/container death closes the session and releases the lock automatically | A `FOR UPDATE` row claim cannot own an HTTP operation: the lock ends at transaction end. Session advisory locks give operation-wide, crash-safe ownership without a long transaction. **Polling only** — enrichment requests belong to no source and never take a source lock |
| Global request gate | **A second session-level advisory lock**, namespaced `(REQUEST_GATE, 1)`: acquire gate → transactionally reserve budget → perform exactly one GitHub request → reconcile response headers → release gate. At most one in-flight live request across poller, worker, and one-shot. **Lock-order invariant:** a polling operation may acquire the source lock and then the gate; no code path may acquire the gate and then attempt a source lock | Makes budget accounting race-free and follows GitHub’s recommendation to make requests serially. Solid Queue concurrency controls alone cannot cover the one-shot command |
| Recurring polling | Solid Queue recurring task fires every 60s → `PollEventSourceJob` computes `effective_poll_time` (Section 9) and no-ops unless a poll is due | Keeps cadence budget-driven and configurable without schedule rewrites |
| HTTP client | Faraday | Middleware seam for the transports and request instrumentation |
| Protocol headers | Every live request sends `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28`, `User-Agent: github-push-ingestor` | GitHub recommends the media type + version header and rejects requests without a valid `User-Agent`. Version pinned to `2022-11-28` — the version all of this plan’s live-probe evidence was gathered under (the documented default when no header is sent; supported until 2028-03-10). The newer `2026-03-10` version exists; upgrading is a deliberate follow-up that re-verifies payload shape under that version first |
| Tests | RSpec + WebMock + hand-authored static JSON fixtures | Deterministic. VCR is intentionally not used because hand-authored scripted fixtures provide deterministic control over conditional responses, retries, changing rate-limit headers, and failure sequences |

Operational defaults (env-tunable, pinned):

```text
HTTP_OPEN_TIMEOUT_SECONDS = 5
HTTP_READ_TIMEOUT_SECONDS = 15
MAX_HTTP_RETRIES          = 2
MAX_REDIRECTS             = 2
SOURCE_LOCK_WAIT_SECONDS  = 30
```

### Docker Compose topology

| Service | Profile | Restart | Role | Notes |
|---|---|---|---|---|
| `db` | — | `unless-stopped` | PostgreSQL 16 | Named volume; `pg_isready` healthcheck |
| `setup` | — | `no` | One-shot `bin/rails db:prepare` | `depends_on: db: condition: service_healthy`. Prepares **both** the primary and queue databases (declared in `database.yml`), so `web`/`worker` never race concurrent `db:prepare` runs |
| `web` | — | `unless-stopped` | Rails API | `depends_on: setup: condition: service_completed_successfully` |
| `worker` | — | `unless-stopped`, `stop_grace_period: 30s` | Solid Queue supervisor (poller + enrichment jobs) | Same image; same `setup` dependency |
| `ingest` | `tools` | `no` | One-shot ingestion (`docker compose run --rm ingest`) | `depends_on: setup: condition: service_completed_successfully`. Profiled so plain `up` never starts it. Semantics in Section 9 |
| `test` | `tools` | `no` | Test suite (`docker compose run --rm test`) | **Depends only on `db: service_healthy`** — runs its own `RAILS_ENV=test bin/rails db:test:prepare && bundle exec rspec`; never invokes the development `setup` service. Isolated test databases for both app and queue (`github_push_ingestor_test`, `github_push_ingestor_queue_test`). Ordinary specs use Active Job’s test adapter; only dedicated queue integration tests touch the queue test database. **Never touches the development databases** |

Docker’s default restart policy is `no`, so crash recovery must be declared: `unless-stopped` restarts `db`/`web`/`worker` after process failure and after a Docker daemon restart, unless deliberately stopped; one-shots never restart. Transient GitHub failures are still handled *inside* the running process by deferral/retry state — they never terminate the worker.

Services without profiles are what a plain `docker compose up --build` starts: `db`, `setup`, `web`, `worker` — continuous polling begins automatically. The `tools`-profiled services run only when explicitly targeted with `docker compose run`.

## 3. Repository and Delivery Workflow

**Repository:** `batbrainy/github-push-ingestor`

**Repository URL:** https://github.com/batbrainy/github-push-ingestor

**Description:**

> Fault-tolerant Rails service for ingesting, enriching, and persisting GitHub Push events.

### Branch strategy

- Use `main` as the long-term default branch.
- Create focused branches named after issues, for example:
  - `issue-3-bootstrap-rails`
  - `issue-7-github-client`
  - `issue-10-event-persistence`
- Open one pull request per coherent capability.
- Prefer squash merging after tests and acceptance checks pass.
- Avoid giant pull requests and avoid trivial one-file pull requests without independent value.

### Pull request expectations

Every pull request should contain:

- Linked issue
- Problem being solved
- Scope of the change
- Important technical decisions
- Testing performed
- Docker verification, where applicable
- Documentation updates
- Known limitations

## 4. GitHub Project and Issue Structure

Create a GitHub Project named:

`GitHub Push Ingestor Delivery`

Suggested fields:

- Status: Backlog, Ready, In Progress, In Review, Done
- Priority: P0, P1, P2
- Type: Story, Task, Test, Documentation
- Requirement: Core, Optional Extension, Engineering

Create one parent tracking issue for each required story and optional extension. Link focused implementation issues underneath each parent.

### Story 1 — Ingest GitHub Push Events

Child issues:

1. Bootstrap Rails API and Docker Compose (profiles, `setup` service, restart policies, readiness gating, isolated test databases)
2. Define event-source adapter contract
3. Implement GitHub Public Events source
4. Implement `Link`-header pagination and poll-state handling
5. Implement `PushEvent` filtering and tolerant normalization
6. Add one-shot ingestion command with defined contention semantics (Section 9)
7. Add recurring polling via Solid Queue recurring task
8. Add duplicate-safe event persistence and restart recovery

### Story 2 — Persist Raw and Structured Data

Child issues:

1. Design and migrate `push_events` (typed columns per Section 7)
2. Preserve raw payload as PostgreSQL `jsonb` (documented as semantic retention)
3. Extract required fields:
   - repository identifier
   - push identifier
   - ref
   - head
   - before
4. Add unique constraints, `NOT NULL` rules, and indexes
5. Add durable quarantine with the canonical fingerprint algorithm, occurrence counting, and the malformed-event taxonomy
6. Add event inspection API
7. Document the data model

### Story 3 — Enrich Push Events

Child issues:

1. Design actor and repository models with the entity-level enrichment state machine
2. Upsert stub actor/repository rows inside the ingest transaction under explicit merge rules (envelope field mappings per Section 7; activity updates gated on newly inserted events)
3. Fetch actor data from payload-provided URLs (validated — Section 10)
4. Fetch repository data from payload-provided URLs (validated — Section 10)
5. Add freshness-based durable caching (entity `fetched_at` + refresh TTLs)
6. Prevent duplicate concurrent enrichment (keyed by entity row)
7. Enforce the hourly enrichment allowance with **per-class fairness shares and borrowing**, the `skipped_budget` state, and the distinct-event reactivation rule
8. Add pending-work reconciliation (entity-scoped scan)
9. Test failed, repeated, skipped, reactivated, replay-non-reactivated, and starved-class enrichment

### Story 4 — Operability and Observability

Child issues:

1. Add structured JSON logging with `LOG_LEVEL` control
2. Add ingestion-run correlation IDs (`run_id` UUID)
3. Add GitHub event IDs and job IDs to logs
4. Add `/health/live` and `/health/ready` endpoints (no GitHub calls, no budget consumption)
5. Add ingestion status endpoint (per-class budget state, defined coverage formulas, pending/skipped counts)
6. Add malformed-payload quarantine handling
7. Add retry and failure logging
8. Add container health checks
9. Document expected logs and verification steps

### Extension A — Rate Limiting and Fan-Out Control

Child issues:

1. Read and reconcile GitHub rate-limit headers (monotonic, reset-window-aware, `x-ratelimit-resource` verified as `core`)
2. Implement the class-aware budget ledger: transactional reservation, the allowance formula, and startup configuration validation
3. Implement the global request gate (session advisory lock; serial outbound concurrency of one; lock-order invariant)
4. Implement the scheduling components (`cadence_due_at`, `poll_floor_until`, `retry_not_before_at`) and the `effective_poll_time` / `effective_enrichment_time` rules
5. Implement `global_blocked_until` (truly global blocks only) and counter-derived class blocking
6. Add ETag / `If-None-Match` scoped to the canonical first-page request (documented as budget-consuming unauthenticated)
7. Handle `304 Not Modified` (reservation stays debited)
8. Handle secondary rate limits globally (`Retry-After` → `global_blocked_until`); add exponential backoff with jitter
9. Implement enrichment fairness shares (floor/remainder rounding) with eligibility-aware borrowing
10. Implement the per-window budget bootstrap (first real poll initializes each window)

### Extension B — Duplicate-safe Event Persistence and Restart Safety

Child issues:

1. Add unique GitHub event constraint
2. Add conflict-safe event persistence (`ON CONFLICT DO NOTHING RETURNING id`)
3. Add merge-rule actor and repository upserts (`ON CONFLICT DO UPDATE`; activity updates only for newly inserted events)
4. Use PostgreSQL-backed jobs (Solid Queue)
5. Preserve pending work in business tables
6. Reconcile work not enqueued before a crash
7. Add crash-safe source ownership (session advisory lock; verify release on session death)
8. Bound the enrichment backlog via the eligibility window and `skipped_budget` state (no unbounded growth)
9. Add Docker restart policies; test API-stop and main-process-crash paths separately
10. Document processing guarantees

### Extension C — Object Storage

**Deliberately not attempted.** Stated explicitly here and in the design brief: the remaining budget of this submission is spent on rate-limit correctness, durability, and reviewer experience, which carry more signal than a fourth extension. (V1 left Extension C as an orphan sentence; V2 makes the omission an explicit decision.)

### Extension D — Testing Strategy

Child issues:

1. Add deterministic GitHub fixtures (static JSON corpus + fixture source + fixture transport)
2. Test `PushEvent` filtering and tolerant parsing
3. Test raw and structured persistence
4. Test duplicate ingestion (including replay-does-not-reactivate)
5. Test pagination stopping conditions (cap / allowance / no-next-link / empty page)
6. Test ETag scoping and `304` behavior (including quota accounting)
7. Test budget-ledger reservation, the allowance formula, fairness rounding/borrowing, per-window bootstrap, and exhaustion (global vs class blocking)
8. Test transient retries
9. Test the canonical fingerprint algorithm and quarantine occurrence counting
10. Test enrichment caching, terminal skip, and distinct-event reactivation
11. Test pending-work recovery and advisory-lock release on session death
12. Add Docker-based end-to-end verification (fixture mode, fail-closed) and container-kill recovery checks

## 5. Proposed Architecture

Two request paths share the executor; only polling takes a source lock:

```text
POLLING PATH                            ENRICHMENT PATH

IngestionRunner                         EnrichActorJob / EnrichRepositoryJob
  → SourceLock(event_source_id)           │
  → EventSource (PublicEvents|Fixture)    │
  → RequestExecutor ◄─────────────────────┘
      → RequestGate (global, serial)
      → BudgetLedger (class-aware, formula-derived, per-window)
      → UrlPolicy
      → Transport: Faraday (live) | Fixture
           |
           v
PostgreSQL Transaction
- raw payload; structured fields
- stub actor/repo upserts (merge rules)
- INSERT … ON CONFLICT DO NOTHING RETURNING id
- activity updates ONLY when a row returned
- malformed-event quarantine (fingerprints)
           |
           v
Solid Queue (PostgreSQL-backed)
           |
     +-----+------+
     |            |
     v            v
Actor Job    Repository Job
 (fair-share   (fair-share
  budgeted)     budgeted)
     |            |
     +-----+------+
           |
           v
PostgreSQL
```

**Lock-order invariant:** source lock → request gate, never the reverse.

**Ownership:** `IngestionRunner` owns the source lock for the duration of a polling operation. `RequestExecutor` does **not** own or acquire `SourceLock` — its chain begins at the request gate and is identical for polling and enrichment.

### Main components

- `Github::Client`
- `Github::RequestExecutor`
- `Github::SourceLock` (session advisory lock, `(SOURCE_LOCK, event_source_id)`; owned by `IngestionRunner`, polling only)
- `Github::RequestGate` (global session advisory lock, `(REQUEST_GATE, 1)`)
- `Github::BudgetLedger` (class-aware; allowance formula; per-window bootstrap)
- `Github::RateLimitPolicy`
- `Github::RetryPolicy`
- `Github::UrlPolicy` (enrichment URL validation)
- `Github::Transports::Faraday`
- `Github::Transports::Fixture`
- `Github::EventSources::Base`
- `Github::EventSources::PublicEvents`
- `Github::EventSources::FixtureEvents`
- `Github::EventSources::RepositoryEvents` — optional extension (documented seam; not built)
- `Github::FetchResult`
- `Github::Events::ProcessorRegistry`
- `Github::Events::PushEventProcessor`
- `Github::IngestionRunner`
- `PollEventSourceJob`
- `EnrichActorJob`
- `EnrichRepositoryJob`
- `ReconcilePendingEnrichmentsJob`

## 6. Event-Source Design

The required delivered source will call:

```text
GET https://api.github.com/events
```

The source adapter isolates endpoint construction and source-specific state from common event processing. Two seams exist, and both ship with two implementations:

- **Event sources**: `PublicEvents` (live endpoint) and `FixtureEvents` (returns deterministic `fixture://events` locations) — so the adapter contract is exercised, not speculative.
- **Transports**: `Faraday` (live HTTP) and `Fixture` (resolves event, actor, and repository fixture URLs entirely offline) — so enrichment is also deterministic in fixture mode.

Fixture mode **fails closed**: if a URL is not present in the corpus, a fixture error is raised. It never falls back to live GitHub.

The event processor registry will initially support only:

```text
PushEvent
```

The application may expose configuration such as:

```text
GITHUB_EVENT_TYPES=PushEvent
```

Configured event types must be validated against implemented processors. Unsupported types should fail fast with a clear configuration error.

A future repository source can use:

```text
GET /repos/{owner}/{repository}/events
```

without rewriting persistence, enrichment, or the push-event processor. Notes for that extension: ETag/304 becomes a genuine cost saver on that low-volume endpoint when authenticated (unlike the global feed — Section 10), and the allowance formula (Section 10) already includes `ENABLED_LIVE_SOURCE_COUNT` — enabling more live sources recalculates the poll allowance, and startup validation rejects configurations whose polling requirement exceeds the available budget.

## 7. Data Model

### `event_sources`

Stores polling and source-specific state, with **separate scheduling components** (Section 9) rather than one collapsed timestamp — required so `--force` can bypass exactly one component:

- `id`
- `source_type`
- `configuration`
- `enabled`
- `status`
- `etag` — applies **only** to the canonical first-page request with its stable query parameters
- `cadence_due_at` — configured cadence
- `poll_floor_until` — from `X-Poll-Interval`
- `retry_not_before_at` — from source-scoped `Retry-After` / backoff
- `next_poll_at` — optional cached effective value
- `last_polled_at`
- `last_success_at`
- `consecutive_failures`
- `last_error`
- timestamps

(V1 stored rate-limit state per source; V2 moves it to the global ledger — enrichment requests aren’t tied to a source row, and the budget is per-IP, not per-source.)

### `github_api_budget` (new in V2 — class-aware, per-window)

Single-row global ledger (constrained singleton), through which **every** outbound live request from any process — poller, worker, one-shot — reserves capacity transactionally before execution.

- `id` — `integer PRIMARY KEY DEFAULT 1 CHECK (id = 1)` (hard schema-level single-row enforcement)
- `resource` — `"core"` (verified against `x-ratelimit-resource` on live responses)
- `limit` — authoritative header value (`x-ratelimit-limit`)
- `remaining` — conservative local estimate, reconciled against headers
- `reset_at` — current window boundary, **informational**
- `global_blocked_until` — populated **only** for truly global blocks (Section 10); class blocking is **derived from counters**, never stored here
- `window_status` — `uninitialized | active | globally_blocked`
- `window_initialized_at`
- `poll_allowance`, `poll_used`
- `enrichment_allowance`, `enrichment_used`
- `actor_share_used`, `repository_share_used` (fairness accounting — Section 10)
- `reserve`
- `observed_at`
- `lock_version`
- timestamps

Allowances are **derived at startup from one formula** (Section 10), not hand-set independently.

Semantics:

- **Reservation before execution.** Every actual outbound attempt debits its class counter transactionally first — `200`, `304`, retries after `5xx`, one-shot polls, actor requests, repository requests. A plain `remaining > reserve` check is not enforcement: without class counters, enrichment could legally consume 52 requests at the top of the hour and leave the twelve scheduled polls nothing. These are **request-attempt allowances**, not guaranteed successful polls — a `500` retry or a forced one-shot request consumes poll allowance and can reduce completed scheduled polls that hour.
- **Failures stay spent.** A network failure without authoritative response headers keeps the reservation consumed; the next successful response reconciles local state with GitHub’s headers.
- **Monotonic reconciliation.** Response headers are authoritative but may arrive out of order; within the same reset window, reconcile with `LEAST(local_remaining, observed_remaining)`. (The global serial request gate makes out-of-order arrival impossible in practice; the monotonic rule is defense in depth.)
- **Per-window bootstrap — the first real poll, not an extra request.** When `window_status = uninitialized` (fresh install, or the previous `reset_at` has passed): counters zero, enrichment temporarily ineligible. The first canonical page-one polling request proceeds under the gate, initializes `limit`/`remaining`/`reset_at`/`observed_at` from its response headers, counts as `poll_used = 1`, and its events are processed normally. Only after the window is `active` may enrichment spend. This matters because another application behind the same IP may have consumed budget immediately after the reset — never assume 60 remaining.
- **The ledger coordinates this application only.** Other software behind the same public IP can consume capacity outside this application; GitHub’s response headers remain the source of truth, and the ledger converges to them.

### `ingestion_runs`

Tracks one polling cycle.

Suggested fields:

- `id` — internal persistence identifier
- `run_id` — UUID; stable correlation identifier across poller, worker, logs, and status output
- `event_source_id`
- `started_at`
- `completed_at`
- `status`
- `pages_fetched`
- `events_received`
- `push_events_seen`
- `events_created`
- `duplicates_skipped`
- `events_quarantined`
- `events_failed`
- `last_error`
- timestamps

### `push_events`

Suggested fields (types pinned):

- `id`
- `github_event_id` — `text`, `NOT NULL` (GitHub event IDs are large numerics delivered as strings)
- `github_push_id` — `bigint`, `NOT NULL`
- `github_repository_id` — `bigint`, `NOT NULL`, FK → `github_repositories.github_id`
- `github_actor_id` — `bigint`, `NOT NULL`, FK → `github_actors.github_id`
- `ref` — `text`, `NOT NULL`
- `head_sha` — `varchar(64)`, `NOT NULL` (payload field `head`; exposed as `head` in serializers/docs)
- `before_sha` — `varchar(64)`, `NOT NULL` (payload field `before`; exposed as `before`)
- `occurred_at` — `NOT NULL`
- `raw_payload` — `jsonb`, `NOT NULL`
- timestamps

SHA validation accepts **40- or 64-character hexadecimal** object names: Git object IDs are 40 hex chars under SHA-1 and 64 under SHA-256, and hard-coding 40 would conflict with the tolerant-parser goal.

Constraints and indexes:

- Unique `github_event_id`; inserts use `ON CONFLICT (github_event_id) DO NOTHING RETURNING id` — an accepted raw event is never mutated by a re-poll, and **the presence of a returned row is what gates entity activity updates** (see `github_actors`)
- Index `github_push_id`
- Index `github_repository_id`
- Index `github_actor_id`
- Index `occurred_at`
- Add a GIN index on `raw_payload` only if a demonstrated query requires it

**Tolerant parsing:** the currently documented required `PushEvent` payload fields are `repository_id`, `push_id`, `ref`, `head`, and `before`. The parser requires these fields but tolerates additional unknown fields — GitHub can add response fields without a new API version — and the entire event is retained in `raw_payload` regardless.

FKs are possible because the ingest transaction upserts stub entity rows first. Enrichment state does **not** live on this table (V2 change): actors and repositories are shared entities, and V1’s per-event status columns could not represent independent actor/repo outcomes with one shared `last_error`/`next_retry_at`.

**Raw retention is semantic, not byte-exact:** PostgreSQL `jsonb` does not preserve whitespace, key order, or duplicate keys. That is sufficient for the assignment’s audit/debug purpose and is stated as a tradeoff in the ADR; byte-exact audit would require a `text`/`json` column and is deliberately not built.

### `quarantined_events` (new in V2)

Durable home for events that fail validation — “malformed” is a defined predicate, not an exception path ending in a log line. A malformed event may be malformed precisely because it lacks an event ID, so **the fingerprint is the only uniqueness constraint** — the same `github_event_id` arriving with a different malformed payload is a *different* quarantine row, not a constraint violation:

- `id`
- `github_event_id` — nullable; **indexed, not unique**
- `payload_fingerprint` — `NOT NULL`, **unique** (sole identity)
- `event_type` — nullable
- `raw_payload` — `jsonb`
- `error_code`, `error_message`
- `first_received_at`, `last_received_at`
- `occurrence_count`
- timestamps

**One canonicalization definition** (no alternates):

```text
payload_fingerprint =
  SHA-256( compact UTF-8 JSON produced after recursively sorting all object keys )
```

Tests cover nested key-order independence, array-order preservation, nulls, booleans, Unicode strings, numerics, and payloads with and without event IDs.

Repeated malformed payloads upsert:

```sql
ON CONFLICT (payload_fingerprint)
DO UPDATE SET
  last_received_at = EXCLUDED.last_received_at,
  occurrence_count = quarantined_events.occurrence_count + 1
```

Malformed-event taxonomy:

| Case | Handling |
|---|---|
| Valid non-`PushEvent` | Ignored and counted — not quarantined |
| `PushEvent` missing a required field | Quarantined |
| Event missing `type` or with an invalid envelope | Quarantined |
| `payload.repository_id` ≠ `repo.id` | Quarantined as an integrity failure |
| Entire HTTP response body is invalid JSON | Ingestion/request failure — not an individual quarantined event |

### `github_actors`

- `id`
- `github_id` — `bigint`, unique
- `login`
- `display_login`
- `name` — nullable; normally populated by enrichment
- `api_url`
- `avatar_url`
- `raw_payload` (full document after enrichment; `NULL` on stubs)
- **Enrichment state machine (entity-level, V2):**
  - `enrichment_status` — `pending | complete | retryable_failure | permanent_failure | skipped_budget`
  - `enrichment_attempts`
  - `next_retry_at`
  - `last_error`
  - `fetched_at`
  - `first_seen_at` — first time a **distinct persisted** push referenced this entity
  - `last_seen_at` — most recent local observation of a **distinct persisted** push; drives the newest-first policy
  - `latest_event_at` — greatest GitHub event `created_at` among distinct persisted pushes
  - `skipped_at`
- timestamps

Envelope-to-stub field mapping (explicit — the envelope and the enriched document are different shapes):

```text
actor.login         → login
actor.display_login → display_login
actor.url           → api_url
actor.avatar_url    → avatar_url
(enrichment populates name and raw_payload)
```

**Stub upsert merge rules** (`ON CONFLICT (github_id) DO UPDATE`), with **activity gated on distinct events**:

1. Upsert entity identity stubs — envelope values may refresh identity fields (login, display_login, API URL, avatar URL) on any observation, including duplicates; an envelope upsert never clears a previously stored enrichment payload or `name`.
2. `INSERT push_events … ON CONFLICT DO NOTHING RETURNING id`.
3. **Only when RETURNING produces a row** (a genuinely new event): update `last_seen_at` and `latest_event_at`, set `first_seen_at` if unset, and apply `skipped_budget` reactivation.
4. A duplicate event replay may refresh harmless identity fields but **can never reactivate enrichment** — otherwise a re-polled window would resurrect skipped entities with no new activity.

A `complete` enrichment is not reset to `pending` by any duplicate; it returns to `pending` only when missing, explicitly stale (past its refresh TTL), or reactivated after a budget skip.

**Reactivation rule:** `skipped_budget` is terminal for the entity’s current eligibility window, not forever. A **newly persisted** push event referencing the entity updates its activity fields and may transition it back to `pending` when its enrichment is missing or stale. This also handles delayed-but-new events correctly: even with an old `created_at` (documented 30s–6h latency), a distinct event ID proves new activity. Partial enrichment is expected by design; pending work is bounded — candidates that age beyond the configured eligibility window transition to `skipped_budget`.

Partial index matching the reconciler’s exact predicate:

```sql
(next_retry_at, last_seen_at) WHERE enrichment_status IN ('pending', 'retryable_failure')
```

### `github_repositories`

- `id`, `github_id` (`bigint`, unique), `name`, `full_name`, `api_url`, `description`, `language`, `owner_github_id`, `raw_payload`, plus the identical enrichment state machine, merge rules, distinct-event activity gating, reactivation rule, partial index, and timestamps.

Envelope-to-stub field mapping — the envelope’s `repo.name` is the qualified `owner/repository` form; it is **not** silently equated with the enriched `name`:

```text
event.repo.name → full_name
name            → final segment of full_name (or NULL until enrichment)
event.repo.url  → api_url
(enrichment populates description, language, owner_github_id, raw_payload)
```

## 8. Durability and Crash Recovery

### Durability boundary

A GitHub event is considered accepted only after its `push_events` row is committed to PostgreSQL.

### Processing sequence

1. Acquire the source’s session advisory lock (Section 2A); hold it across the operation. (Enrichment jobs skip this step — they take only the request gate.)
2. Fetch a page from GitHub (through the request gate and budget ledger).
3. Validate the response.
4. Filter `PushEvent` entries; route valid non-push events to counters.
5. Normalize required attributes tolerantly; route failures to `quarantined_events`.
6. Upsert stub actor and repository rows (identity fields only).
7. Insert the raw and structured event row with conflict skipping (`RETURNING id`).
8. For rows actually inserted: apply entity activity updates and reactivation (Section 7).
9. Commit the PostgreSQL transaction (short-lived — the advisory lock, not the transaction, spans the HTTP work).
10. Enqueue enrichment after commit — Solid Queue lives in its own database, so same-transaction enqueue is not available; the committed entity state is the durable record of pending work (outbox-style recovery, per Section 2A).
11. Reconcile entities whose enrichment was not scheduled or completed.
12. Release the advisory lock (`ensure`); session death releases it automatically.

### Crash behavior

#### Crash before commit

The transaction rolls back; the session advisory lock releases with the dead session. The
event is recoverable only if it remains present in a later response from GitHub's sliding
feed. If the window advances past it first, this service does not recover it.

#### Crash after commit

The event and its stub entities remain durable in PostgreSQL. Docker restarts the crashed container (`unless-stopped`). Pending enrichment is rediscovered after restart by scanning entity rows — a small, entity-scoped set, not N event rows per entity.

#### Worker crash before enrichment commit

The job is retried.

#### Worker crash after enrichment commit but before acknowledgement

The job may execute again. Selector leases, freshness checks, and constrained upserts
prevent duplicate entity rows, but execution and operational side effects may repeat.

### Processing semantics

Repeated observation and job delivery are expected. The system enforces two narrower
invariants: a duplicate GitHub event ID cannot create another `push_events` row, and that
duplicate cannot register entity activity or reactivate a `skipped_budget` entity. A
duplicate may refresh permitted identity fields. Executions, `ingestion_runs`, quarantine
occurrence counts, budget debits, and logs may repeat or change. The system does not claim
exactly-once execution or universal idempotency of persisted state.

### Docker persistence

PostgreSQL will use a named Docker volume. Normal container stop, restart, crash,
recreation, or `docker compose down` must not remove stored events. An explicit volume
deletion is treated as an intentional destructive reset. Restart policies (Section 2A)
recover main-process crashes automatically; a daemon API stop such as `docker kill` leaves
the container down until an operator recreates it. Section 15 verifies both paths.

## 9. Polling, Pagination, and Concurrency

### Poll scheduling

Scheduling constraints are persisted as **separate components** (Section 7) — never collapsed into one timestamp, or `--force` could not tell which part it may bypass, and a routine `X-RateLimit-Reset` would wrongly defer every poll to the top of the hour:

```text
effective_poll_time(force:) = max(
  force ? nil : cadence_due_at,          # POLL_INTERVAL_SECONDS, default 300
  poll_floor_until,                      # X-Poll-Interval (observed 60) — server floor, must be obeyed
  retry_not_before_at,                   # source-scoped Retry-After / backoff, when present
  global_blocked_until,                  # truly global blocks only (Section 10)
  poll_class_blocked_until               # derived: poll_used >= poll_allowance ? reset_at : nil
)
```

Enrichment workers schedule independently — class exhaustion in one class never stops the other, and polling never stops because enrichment ran dry:

```text
effective_enrichment_time = max(
  entity.next_retry_at,
  global_blocked_until,
  enrichment_class_blocked_until         # derived: enrichment_used >= enrichment_allowance ? reset_at : nil
)
```

`reset_at` is informational; it never participates in scheduling directly. With defaults: configured cadence 300s, observed floor 60s → effective normal cadence 300s.

### Pagination

- Request `per_page=100`; follow the **`Link` response header** for subsequent pages (GitHub’s documented recommendation) rather than constructing page URLs, while still enforcing `MAX_PAGES_PER_POLL`
- `MAX_PAGES_PER_POLL` default **1** (raising it trades enrichment allowance for capture depth via the allowance formula — Section 10)
- Stop when:
  - the configured page cap is reached
  - the budget ledger denies the next reservation
  - no next `Link` exists
  - an empty page is returned

**No stop-on-known-event for the live source.** Documented event latency is 30s–6h, and the API does not guarantee that one previously seen event implies all older positions are already stored — a delayed event can surface later near an already-seen one. Every fetched page is processed in full; `github_event_id` uniqueness absorbs duplicates. (The known-event stop remains valid inside deterministic fixture scenarios where ordering is authored.)

**ETag scope.** The persisted source ETag applies only to the canonical first-page request, including its stable query parameters. Subsequent `Link` pages are fetched without reusing the first-page ETag. During the 2026-07-28 probes, consecutive global-feed polls showed little or no overlap; live overlap is **not relied upon for correctness**.

### Polling state

Persist per source: ETag (page-1 scope), the scheduling components, last successful poll time, consecutive-failure count. Budget state is global (`github_api_budget`), not per source.

### One-shot ingestion vs. the always-on poller

`docker compose run --rm ingest` runs while the `worker` poller may be live. Its contract:

- Retry `pg_try_advisory_lock` on the source key for up to `SOURCE_LOCK_WAIT_SECONDS` (30); if still unavailable, print a clear outcome (“source busy — poller cycle in progress”) plus the state summary below, and exit 0.
- By default it honors `effective_poll_time` and reports “deferred until T” if a poll is not yet due.
- **`--force` bypasses the application’s configured cadence (`cadence_due_at`) and omits the stored ETag — nothing else.** It does not bypass the source lock, `poll_floor_until`, `retry_not_before_at`, `global_blocked_until`, class blocking, or the reserve policy. The demo can never blow the budget or violate GitHub’s floor.
- All of its requests pass through the same request gate and budget ledger as the poller and worker.
- **Its stdout always proves system state**, even when deferred or busy:

```text
Ingestion deferred until 2026-07-29T14:05:00Z
Latest successful run:            2026-07-29T14:00:12Z (run_id …)
Persisted push events:            1,284
Pending actor enrichments:        312
Pending repository enrichments:   407
Budget remaining (core):          31 (window resets 14:32:00Z)
```

On a live run it prints the end-of-run summary: pages fetched, events seen, push events created, duplicates skipped, events quarantined, budget remaining.

### Multiple poller containers

Multiple poller or worker containers must not cause the same source to be polled concurrently:

- Session advisory lock per source (operation-wide ownership; auto-released on session death)
- The global request gate (at most one outbound GitHub request in flight, application-wide)
- Solid Queue concurrency limits keyed by source ID (job-level de-duplication)
- Unique event constraints as final duplicate protection

### Multiple event sources

Each event source maintains independent ETag, scheduling components, failure state, and configuration. All unauthenticated requests behind one outbound IP share the single global budget — which is why the ledger is global and persisted. `ENABLED_LIVE_SOURCE_COUNT` feeds the allowance formula (Section 10); startup validation rejects configurations whose polling requirement leaves no enrichment capacity.

## 10. Rate-Limit and Retry Policy

`RequestExecutor`’s chain — identical for every live request — is: global gate → class-aware ledger reservation → validated URL → live transport. The source lock sits *outside* the executor: `IngestionRunner` acquires it around the whole polling operation, and enrichment never takes one (Section 5).

### Request budget (one authoritative formula)

Documented constraints (official GitHub docs, verified during the review rounds):

- Unauthenticated primary limit: **60 requests/hour, associated with the originating IP**; non-search REST endpoints share the `core` rate-limit resource, so `/events`, actor retrieval, and repository retrieval compete for one budget. The `x-ratelimit-resource` header is processed and verified to be `core` for all live request types.
- `X-Poll-Interval` specifies how frequently the client is allowed to poll and must be obeyed — a floor, not a target.
- The `/events` window is up to 300 events (3 pages at `per_page=100`); retention is 30 days; documented latency is 30s–6h.
- GitHub recommends using response headers for limit state rather than extra status requests, making requests serially, and waiting until `X-RateLimit-Reset` **when the remaining count is zero** — not after every request.

**Unauthenticated `304` accounting.** The endpoint documentation contains a general statement that `304` responses do not affect the rate limit, while GitHub’s REST best-practices documentation limits that exemption to correctly authorized requests. Two dated unauthenticated probes (review-supplied evidence, 2026-07-28) showed `x-ratelimit-used` increasing across a `304` (one transcript: 200 → used 4, remaining 56; immediate conditional replay → 304, used 5, remaining 55). This implementation therefore budgets every unauthenticated request — including `304`s — as one request. ETag remains a bandwidth/correctness measure, never a quota saver, in this configuration. **PR 6 re-runs and commits a dated probe transcript as a required validation gate** — normal `GET`, explicit `X-GitHub-Api-Version: 2022-11-28`, exact UTC timestamps, ETag, and complete before/after rate-limit headers — so the design brief cites first-party evidence.

**Allowance formula**, computed at startup and on configuration change:

```text
poll_attempt_allowance =
  ceil(3600 / POLL_INTERVAL_SECONDS)
  × MAX_PAGES_PER_POLL
  × ENABLED_LIVE_SOURCE_COUNT

enrichment_allowance =
  rate_limit − RATE_LIMIT_RESERVE − poll_attempt_allowance
```

With defaults:

```text
ceil(3600 / 300) × 1 × 1 = 12 poll attempts/hour
60 − 8 − 12              = 40 enrichment attempts/hour
```

| Allocation | Default |
|---|---:|
| Scheduled polling | 12 request-attempts/hour |
| Enrichment | up to 40 request-attempts/hour |
| Intentionally unspent reserve | 8 requests/hour |
| **Total** | **60 requests/hour** |

Startup validation **rejects** any configuration where `poll_attempt_allowance + reserve >= effective_limit` — that would leave no capacity for required Story 3 enrichment.

**Global vs class blocking — one timestamp cannot serve both.** The stored `global_blocked_until` covers only conditions that must stop *all* live requests:

- primary rate limit exhausted (`X-RateLimit-Remaining` = 0) → defer to `reset_at`
- usable budget has reached the global reserve
- a secondary rate limit (below)

Class blocking is **derived from counters**, never stored globally:

```text
poll_class_blocked_until       = poll_used >= poll_allowance ? reset_at : nil
enrichment_class_blocked_until = enrichment_used >= enrichment_allowance ? reset_at : nil
```

So enrichment exhausting its 40 attempts never stops polling, and polling exhausting its 12 never stops enrichment. Actor/repository share exhaustion lives inside `BudgetLedger.reserve!(:actor | :repository)` and never touches the global block. A routine future `X-RateLimit-Reset` on a successful response never defers anything.

**Secondary rate limits are global.** They are IP-scoped, and they can arise on *any* live request — including enrichment, which has no source row. On any secondary-limit response: set `global_blocked_until` from `Retry-After` (or ≥ 1 minute with exponential backoff when the header is absent), also update the request-specific source or entity retry state, and stop all live requests until the block expires.

**Per-window bootstrap.** See Section 7: the first canonical page-one poll of each rate-limit window initializes the ledger from authoritative headers (it is a normal, counted, event-processing poll — not an extra discovery request); enrichment is ineligible until the window is `active`.

Consequence, stated honestly: one observed live page of `/events` held ~92–95 PushEvents with ~89 distinct actors and ~92 distinct repositories:

```text
89 actors + 92 repositories = 181 entity requests/page (cold)
181 × 12 polls/hour ≈ 2,172 requests/hour of cold demand
40 available enrichments/hour ≈ 1.8% theoretical cold coverage
```

**Enrichment is best-effort sampling by design**, and it must be **fair across classes**: repository candidates alone exceed the entire hourly allowance, so a naive repo-first policy would starve actor enrichment to zero indefinitely — violating Story 3, which requires both. Fairness policy with explicit rounding:

```text
actor_guarantee      = floor(enrichment_allowance × ACTOR_ENRICHMENT_SHARE)
repository_guarantee = enrichment_allowance − actor_guarantee

Defaults: ACTOR_ENRICHMENT_SHARE = 0.50 → 20 actor / 20 repository

Borrowing: a class may borrow the other’s unused capacity only when the
other class has no CURRENTLY ELIGIBLE candidate (not merely no rows).
```

Within each class, never-enriched `pending` candidates always precede TTL-stale refreshes — a refresh spends budget only when no pending candidate is currently eligible. Among pending candidates the service enriches newest-first (`last_seen_at`); candidates that age beyond the eligibility window transition to `skipped_budget`, and entities referenced by newly persisted events reactivate (Section 7). The backlog is therefore bounded, `skipped_budget` is a normal documented outcome, and `/status` reports per-class usage and coverage so an operator sees the sampling rate instead of a mysteriously growing queue.

Timing configuration (pinned defaults; tunable):

```text
ENRICHMENT_ELIGIBILITY_WINDOW_SECONDS = 3600
ACTOR_REFRESH_TTL_SECONDS             = 86400
REPOSITORY_REFRESH_TTL_SECONDS        = 86400
ENRICHMENT_COVERAGE_WINDOW_SECONDS    = 86400
```

### Enrichment URL validation (SSRF boundary)

Enrichment follows URLs supplied inside event payloads, so a strict trust boundary applies:

- HTTPS only; hostname exactly `api.github.com` (case-insensitive)
- No URL userinfo; no non-default port; no IP-literal host
- Redirects: bounded count (`MAX_REDIRECTS`), each target re-validated against this policy before following
- Fixture mode permits only the fixture URI scheme/host and fails closed
- No arbitrary external URL is ever fetched
- Violations mark the entity `permanent_failure`

### Headers to process

- `ETag`
- `X-Poll-Interval`
- `X-RateLimit-Limit`
- `X-RateLimit-Remaining`
- `X-RateLimit-Reset`
- `X-RateLimit-Used`
- `X-RateLimit-Resource`
- `Retry-After`

### Response behavior

#### `200 OK`

- Process response
- Reconcile the ledger from response headers (monotonic within the reset window; verify `x-ratelimit-resource: core`)
- Save ETag (page-1 requests only)
- Schedule next poll via `effective_poll_time`

#### `304 Not Modified`

- Perform no event processing
- **The reservation stays debited — unauthenticated `304`s consume quota**
- Schedule next poll via `effective_poll_time`

#### `403` or `429` with exhausted quota

- Do not retry immediately
- Set `global_blocked_until` from the reset time; `window_status = globally_blocked`
- Record rate-limited status
- Log remaining and reset metadata

#### Secondary rate limit

- Set `global_blocked_until` from `Retry-After` (or ≥ 1 minute + exponential backoff when absent) — all live requests stop
- Also update the request-specific source/entity retry state
- Stop after bounded attempts

#### `5xx` or network timeout

- Retry up to `MAX_HTTP_RETRIES` through the same gate and ledger (each attempt is a reservation)
- Use exponential backoff with jitter
- Persist failure after attempts are exhausted
- Do not crash-loop

#### Permanent client or configuration error — classified by request context

```text
/events returns permanent 4xx        → source failed/disabled
actor or repo URL returns 404/410    → entity permanent_failure; source stays enabled
actor/repo response malformed        → entity permanent_failure or retryable_failure per classification
```

Never disable the event source because one enrichment target disappeared.

### Request prioritization

1. Polling for new events (from `poll_attempt_allowance`)
2. Actor and repository enrichment (from `enrichment_allowance`, under the fairness guarantees — neither class can starve the other)
3. Refreshing stale enrichment (within each class’s share, and only when no never-enriched pending candidate is eligible)

Polling receives priority because raw-event capture is more time-sensitive than enrichment — and the enrichment slice is guaranteed by its own allowance rather than starved by priority alone.

## 11. Observability

### Logging

Structured JSON to stdout/stderr, with a `LOG_LEVEL` env (default `info`).

- **INFO**: ingestion run started/completed with summary counts (persisted, duplicates, quarantined, ignored non-push), enrichment completed/failed/skipped/reactivated, retry scheduled, budget state transitions (window initialized, `global_blocked_until` set/cleared, class exhaustion), source lock acquired/busy, reconciliation summaries
- **DEBUG**: per-request and per-page lines (GitHub request/response, page processed, `304` received)

Rails and ActiveJob framework logging is routed through the same JSON formatter so `docker compose logs -f` stays one coherent stream — the INFO stream is sized so the events Story 4 asks reviewers to see are not buried.

Common fields: timestamp, level, service, environment, event name, `run_id`, job ID, GitHub event ID, event-source ID, actor ID, repository ID, attempt number, HTTP status, duration, budget remaining, error class, error message. (`run_id` is the UUID correlation identifier from `ingestion_runs`; V1’s third per-HTTP request ID is dropped — run ID + job ID cover the flows reviewers trace.)

### Health and inspection endpoints

- `GET /health/live` — process is running. **Never calls GitHub, never consumes budget.**
- `GET /health/ready` — primary database reachable and required schema present. Same guarantee.
- `GET /status` — reports persisted state only; **never initiates a GitHub request**:
  - poll state (scheduling components, last run)
  - ledger state: window status, per-class used/allowance (`actor_requests_used/available`, `repository_requests_used/available`, poll used/allowance), `remaining`, `reset_at`, `global_blocked_until`, reserve
  - enrichment coverage, computed over `ENRICHMENT_COVERAGE_WINDOW_SECONDS` with **defined formulas**:

```text
actor_coverage_pct =
  complete actors referenced by distinct persisted push events in the coverage window
  ÷ all actors referenced by distinct persisted push events in the coverage window

repository_coverage_pct = (same, for repositories)

events_with_both_entities_enriched_pct =
  distinct persisted push events in the window whose joined actor AND repository are both complete
  ÷ all distinct persisted push events in the window
```

  - `pending_actor_count`, `pending_repository_count`, `skipped_actor_count`, `skipped_repository_count`
- `GET /api/push_events`
- `GET /api/push_events/:id`

Optional: `GET /api/actors/:id`, `GET /api/repositories/:id`, `GET /api/ingestion_runs`

## 12. Testing Strategy

Testing focuses on correctness boundaries rather than exhaustive framework behavior.

**Tooling (pinned):** RSpec; WebMock; hand-authored static JSON fixture corpus. VCR is intentionally not used because hand-authored scripted fixtures provide deterministic control over conditional responses, retries, changing rate-limit headers, and failure sequences (Section 2A).

**Fixture mode, first-class and fail-closed:** `GITHUB_MODE=fixture` selects the `FixtureEvents` source and the `Fixture` transport (Section 6) — beneath both polling *and* enrichment, so the complete flow (poll → persist → stub → enrich) runs with zero network. The corpus contains event pages, actor documents, and repository documents whose URLs resolve within the corpus, plus scripted responses: `304` with ETag, `403` with `X-RateLimit-*` exhaustion headers, `500`. The corpus also includes **multi-page event sequences with `Link` headers** (`next`/`last`), so `Link`-driven pagination and the page-cap/allowance stop conditions are exercised entirely offline. Unknown URL → fixture error, never live fallback. One corpus serves unit stubs, integration tests, and the reviewer-facing Docker e2e scenario.

### Unit tests

- Event-source request construction and protocol headers
- Tolerant push-event normalization (required fields enforced, unknown fields ignored; 40- and 64-char SHAs accepted) and quarantine taxonomy routing
- Canonical fingerprint algorithm (nested key-order independence, array-order preservation, nulls, booleans, Unicode, numerics, with/without event IDs)
- Processor registry validation
- Retry and error-context classification (source vs entity)
- Ledger accounting: class reservation, the allowance formula and startup validation, `304` debits, failure-stays-spent, monotonic reconciliation, per-window bootstrap and counter reset, global vs class blocking derivation
- `effective_poll_time` / `effective_enrichment_time` (components independent; `global_blocked_until` only for global conditions; `--force` bypasses cadence + ETag only)
- Fairness rounding (floor/remainder) and eligibility-aware borrowing
- Enrichment URL policy (reject non-HTTPS, wrong host, userinfo, ports, IP literals, unbounded redirects)
- Pagination stop logic (`Link`-header driven; cap / allowance / no-next / empty)
- Enrichment state machine transitions, including distinct-event reactivation and replay-non-reactivation

### Persistence tests

- Unique GitHub event ID (`DO NOTHING RETURNING id` on conflict)
- Raw JSON retention (semantic — assert content equivalence, not byte equality)
- Required structured fields, types, and `NOT NULL` rules
- Stub upsert merge rules (identity refresh on duplicates; activity updates only when a new row was inserted; envelope never clears enrichment or `name`; repo `full_name` mapping)
- Quarantine fingerprint as sole unique key (same event ID + different malformed payloads coexist); occurrence-count upsert
- Pending-status queries against the partial indexes

### Integration tests

- Public-event response ingestion
- Non-push events ignored and counted
- Duplicate poll results (fixture replay) — duplicates skipped **and no entity reactivation occurs**
- Multiple-page ingestion via `Link` headers; full-page processing with duplicates absorbed by uniqueness (no known-event stop)
- Actor and repository enrichment via stub → `complete` transitions
- Reuse of fresh enriched records; TTL-driven staleness
- Enrichment allowance exhaustion → deferred → `skipped_budget` → reactivation only via a genuinely new event
- Class fairness: repository flood cannot starve actors (and vice versa); borrowing only when the other class has no eligible candidate
- Poll allowance protected from enrichment demand — and vice versa (class-blocking isolation: one class exhausted, the other proceeds)
- Rate-limit exhaustion (`403` + headers → `global_blocked_until`); routine `reset_at` never defers; secondary limit blocks globally including enrichment
- Per-window bootstrap: new window → counters reset → enrichment ineligible until the first poll initializes it
- `304 Not Modified` (processing skipped, quota debited)
- Transient GitHub failure
- Malformed events quarantined per taxonomy without terminating the batch

### Recovery tests

- Event committed but job not scheduled (reconciler sweep)
- Pending enrichment rediscovered (entity-scoped)
- Enrichment job executed twice
- Worker failure before completion
- Advisory locks released on session death (simulated connection kill)
- Multiple pollers attempt the same source
- Daemon API-stop semantics plus host-PID-namespace process-crash recovery (manual reviewer script — Section 15)

### End-to-end verification

The fixture scenario is the deterministic reviewer path: known corpus in, exact expected counts out (`N` push events, `M` actors, `K` repositories, `D` duplicates skipped, `Q` quarantined), zero live quota consumed. Live ingestion against the public endpoint remains the default runtime behavior.

## 13. Pull Request Plan

Each pull request delivers a coherent, independently reviewable capability. **Dependency-ordered**: the request gate and budget ledger cores land in PR 4, *before* every PR that spends budget — so “PRs 1–8 are shippable core” is literally true. PRs 9–11 hold the advanced tiers.

### PR 1 — Repository foundation
Finalized implementation plan (revision history in Git and Appendices A–D), README skeleton, license, PR template, GitHub Actions skeleton

### PR 2 — Rails and Docker bootstrap
Rails 8.1 API-only app on Ruby 3.4.10; PostgreSQL; Dockerfile; Docker Compose per the Section 2A topology (profiles, `setup` service, restart policies, `pg_isready` healthcheck, `service_completed_successfully` gating, isolated app + queue test databases, `test` depending only on `db`); environment template; `/health/live` + `/health/ready`; base JSON log formatter; container health checks

### PR 3 — Core data model
`event_sources` (scheduling components), `github_api_budget` (window fields, class counters), `ingestion_runs`, `push_events`, `quarantined_events` (fingerprint-unique), `github_actors`, `github_repositories`; typed columns, constraints, `NOT NULL` rules, merge-rule upserts, partial indexes; model tests. CI runs the real suite from this PR onward

### PR 4 — GitHub request infrastructure
`Github::SourceLock` (namespaced session advisory lock, polling-only) and `Github::RequestGate` with the lock-order invariant; **`Github::BudgetLedger` core: transactional reservation, allowance formula, startup validation, per-window bootstrap**; live + fixture transports; public + fixture event sources; protocol headers; `Github::UrlPolicy`; timeout/retry defaults; basic response classification; fixture corpus

### PR 5 — Push-event ingestion
Processor registry; tolerant `PushEvent` processor; quarantine taxonomy + canonical fingerprints; stub entity upserts with envelope mappings and distinct-event activity gating (`RETURNING id`); raw + structured persistence; conflict-safe event insertion and explicit entity merge rules; one-shot ingestion command with contention contract and state summary; ingestion run summaries and persisted/duplicate/quarantined logging

### PR 6 — Poll budget and scheduling
Poll-attempt allowance enforcement; `Link`-header pagination with budget-bounded stops (no known-event stop, ETag scoped to page 1); corrected `304` debit; `effective_poll_time` with independent components; `global_blocked_until` vs derived class blocking; secondary-limit global handling; `Retry-After` handling; persisted poll state; **committed dated live-probe transcript for the 304 finding (required validation gate)**

### PR 7 — Enrichment budget and fairness
Actor/repository enrichment against the entity state machine; fairness guarantees (floor/remainder rounding) with eligibility-aware borrowing; newest-first eligibility; `skipped_budget` + distinct-event reactivation; freshness cache + refresh TTLs; error-context classification (entity vs source); `effective_enrichment_time`

### PR 8 — Background processing and recovery
Solid Queue setup (own database in the same Postgres container); worker container; recurring polling task; enrichment jobs; post-commit enqueue; entity-scoped reconciler; recovery tests (including advisory-lock release on session death)

### PR 9 — Advanced budget hardening
Dynamic multi-source allocation validation; shared-IP reconciliation edge cases; ledger bootstrap edge cases; stress/concurrency tests; budget observability; advanced configuration validation

### PR 10 — Operational enhancements
Rich `/status` (window status, per-class ledger state, defined coverage formulas, state counts); additional inspection endpoints; extended failure and retry logging

### PR 11 — Advanced failure and concurrency validation
Crash-window tests; multi-poller concurrency tests; class-isolation and fairness stress tests; fixture-mode Docker e2e; container-kill recovery verification

### PR 12 — Reviewer documentation and final hardening
Complete README; complete design brief; architecture diagram; “How to verify it’s working”; sample logs; database inspection commands; clean-checkout verification; final quality review; and a reusable submission checklist.

### Descope ladder

1. Cut PR 11’s advanced scenarios first, retaining the required tests that live in PRs 3–8.
2. Cut PR 10’s enhancements, retaining health, logs, and basic status.
3. Cut PR 9 entirely if needed — the *core* gate, ledger, scheduling, and fairness behavior already shipped in PRs 4–7 and is never cut.
4. Never cut PR 12’s documentation or clean-checkout verification.

## 14. Documentation Deliverables

File locations: `IMPLEMENTATION_PLAN.md` at the repository root; `DESIGN_BRIEF.md` and ADRs under `docs/`.

### `README.md`

Must include:

- Pointer to `IMPLEMENTATION_PLAN.md`, noting its revision history lives in Git and Appendices A–D
- Problem overview
- Architecture summary
- Requirements
- Environment variables (budget knobs, fairness shares, TTLs, timeouts, `GITHUB_MODE`, `LOG_LEVEL`)
- Clean-checkout startup
- One-shot ingestion command (default, `--force`, and deferred/busy output semantics)
- Continuous ingestion behavior
- Test command
- Log inspection command
- API inspection examples
- Database verification examples
- Expected time before records appear — grounded in GitHub’s documented 30s–6h event latency plus the 5-minute default poll cadence, and the 30-day retention window
- Fixture-based deterministic verification with exact expected counts
- Rate-limit behavior: the allowance formula, the budget table, global-vs-class blocking, and per-window bootstrap
- Separate API-stop and main-process-crash verification steps (Section 15)
- Reset instructions
- Known limitations (sampling-based enrichment coverage; no guaranteed complete capture; shared-IP budget interference)

Required reviewer commands:

```bash
docker compose up --build
docker compose run --rm ingest
docker compose run --rm test
docker compose logs -f
```

### `docs/DESIGN_BRIEF.md`

Keep within one to two pages — the brief is the reviewer’s primary architecture document; this plan is the internal execution and traceability artifact. Cover:

- Understanding of the business problem
- Architecture
- Data model
- Durability boundary
- **The request-budget formula and table, and the unauthenticated `304` finding** — worded precisely: the endpoint documentation contains a general statement that `304` responses do not affect the rate limit, while the REST best-practices documentation limits that exemption to correctly authorized requests; dated unauthenticated probes showed `x-ratelimit-used` increasing across a `304`; this implementation therefore budgets unauthenticated conditional requests as one request
- **Enrichment as bounded best-effort sampling with per-class fairness; eligibility windows, `skipped_budget`, and distinct-event reactivation as the answer to unbounded growth**
- Duplicate-safe event persistence and restart recovery (advisory-lock ownership; outbox-style recovery; Docker restart policies)
- Enrichment strategy and the SSRF boundary
- Tradeoffs and assumptions (including `jsonb` semantic retention)
- Intentional omissions (Extension C; authentication; complete capture)
- Future scaling path (a larger authenticated allowance could materially increase feasible coverage without guaranteeing capture or enrichment; API-version upgrade to `2026-03-10` after payload re-verification)

### Plan history

The plan’s pre-implementation revision history is preserved in Git history and summarized in Appendices A–D — the review-driven revision rounds are themselves submission-worthy evidence of process. At completion, add a short execution summary describing what changed from this plan during the build and why.

### Architecture Decision Records (`docs/adr/`)

Short ADRs for:

- Solid Queue + post-commit enqueue with durable work-state reconciliation (outbox-style recovery; separate queue database; `enqueue_after_transaction_commit`)
- Session advisory locks for source ownership and the global request gate (vs `FOR UPDATE` row claims; lock-order invariant)
- Repeated execution with duplicate-safe event writes and distinct-event activity gating
- Event-source adapter and transport seams, each with a shipped fixture implementation
- Class-aware budget ledger, allowance formula, global-vs-class blocking, and the enrichment fairness/sampling policy
- `jsonb` semantic retention (not byte-exact)
- Pinned API version `2022-11-28` (evidence gathered under it) with the `2026-03-10` upgrade path
- Why Kafka was not selected

## 15. Reviewer Verification

The README must provide exact steps to:

1. Start all services.
2. Wait for health checks (`/health/ready`).
3. Run one-shot ingestion — noting that a “deferred/busy” result is valid and still proves system state via its summary output.
4. Follow application and worker logs.
5. Query persisted push events.
6. Inspect PostgreSQL record counts.
7. Run the fixture replay scenario and confirm `duplicates_skipped > 0` in the summary — and that no skipped entity was reactivated by the replay. (Live re-runs are not relied upon to demonstrate dedup: probe-dated observations showed little or no overlap between consecutive live polls.)
8. **Verify operator-stop semantics and restart-policy crash recovery as separate paths:**

```bash
GITHUB_MODE=fixture docker compose up --build -d
GITHUB_MODE=fixture script/verify_recovery.sh --confirm
```

The script exercises `db`, `web`, and `worker` twice each. Its `docker kill` path proves
that a daemon API stop leaves an `unless-stopped` container down, records the unchanged
`push_events` count, and performs the required operator recreation. Its process-crash path
uses a privileged helper in the host PID namespace to signal the container's main process;
that path must increment `RestartCount`, recover without an operator step, preserve the
event count, and retain fixture mode in the recreated worker. Neither result may be used as
evidence for the other.

9. Restart containers normally (`docker compose restart`) and confirm existing records remain.
10. Run the full deterministic fixture scenario and compare against the documented expected counts.
11. Run tests.

## 16. Final Quality Gates

### Functional

- Public GitHub Events API works without a token
- Only `PushEvent` records are processed
- Required fields are structured, typed, and `NOT NULL`; unknown payload fields tolerated; 40- and 64-char SHAs accepted
- Raw payload is retained (semantic retention, documented)
- **Both actor and repository enrichment demonstrably occur** within their fairness guarantees
- Duplicate event IDs cannot create another `push_events` row, and duplicate replays never reactivate skipped entities
- `Link`-header pagination is handled; every fetched page fully processed
- Rate-limit behavior is demonstrated: `304` quota accounting, class-aware ledger enforcement, global-vs-class blocking, per-window bootstrap, scheduling rules
- Malformed data is quarantined durably per the taxonomy (canonical fingerprints, occurrence-counted) and does not terminate the batch

### Durability

- PostgreSQL uses a named volume
- Docker restart policies recover main-process crashes in `db`/`web`/`worker` automatically (verified by the script's host-PID-namespace crash path)
- A daemon API stop leaves an `unless-stopped` container down until operator recreation (verified independently by the script's `docker kill` path)
- Application restart preserves events
- Worker restart preserves pending work
- An event row committed before a crash remains stored
- Advisory locks provably release on session death (tested)
- The covered enrichment redelivery cannot create another entity row
- Reconciliation recovers missing enrichment scheduling
- The enrichment backlog is bounded (eligibility window + `skipped_budget` + distinct-event reactivation)

### Operability

- Logs are readable through `docker compose logs -f` at the default level
- Correlation fields (`run_id`, job ID) are present
- `/health/live` and `/health/ready` are meaningful and never consume budget
- `/status` reports window status, poll state, per-class ledger state, pending/skipped counts, and coverage percentages computed by the defined formulas — without initiating GitHub requests
- Retry behavior is visible
- Failures contain actionable context

### Reviewer experience

- Clean checkout works
- No local Ruby or PostgreSQL installation is required
- Commands match the assignment; plain `docker compose up --build` starts exactly `db`, `setup`, `web`, `worker`
- `docker compose run --rm test` never touches the development databases (app or queue) and never triggers the development `setup` service
- Documentation is accurate; the README points to this plan and its appendix revision record
- No secrets or token are required
- Tests are deterministic
- GitHub Project and issues show organized execution
- Pull requests are focused and linked to issues

### Final repository review

- No secrets
- No personal access token
- No stale documentation
- No dead or speculative infrastructure
- No misleading guarantee of complete upstream event capture
- No claim of exactly-once execution
- No claim that enrichment coverage is complete
- No failing or flaky tests

## 17. Delivery Principle

The submission should demonstrate staff-level judgment through reliability, boundaries, failure handling, and communication—not through the number of infrastructure components.

The target is a system that is:

- Small enough to understand
- Complete enough to trust
- Extensible without being speculative
- Durable across normal container and process failures
- Honest about the limitations of the GitHub polling source — including the arithmetic that makes enrichment a bounded sample

---

## Appendix A — Changes from V1 (adversarial design review, 2026-07-28)

*V1, the initial plan, is preserved in Git history (commit `d71299c`, “Initial implementation plan”).*

Each change came out of a multi-lens adversarial review with independent verification; API claims were checked against official GitHub documentation **and live unauthenticated probes of api.github.com** (probe transcripts are review-supplied evidence; PR 6 re-captures a dated first-party transcript as a required gate).

| # | Change | Evidence |
|---|---|---|
| 1 | **304 handling corrected: unauthenticated 304s consume quota.** V1’s 304 branch scheduled the next poll from `X-Poll-Interval`, which only makes sense if 304s were free. | Two independent live probes: conditional `If-None-Match` request to `/events` returned HTTP 304 with `x-ratelimit-used` incremented (one transcript: used 4→5, remaining 56→55). Best-practices doc scopes the 304 exemption to requests “correctly authorized with an Authorization header”; the events page carries a broader unqualified statement |
| 2 | **Request-budget arithmetic added, cadence derived from budget.** V1 had mechanisms but no numbers: polling at `X-Poll-Interval` (60s) = 60 req/hr = 100% of the budget at 1 page (300% at 3 pages), starving required Story 3 enrichment. | Rate-limits doc: 60 req/hr unauthenticated, IP-keyed; live headers: `x-ratelimit-limit: 60`, `x-poll-interval: 60` on both 200 and 304, `x-ratelimit-resource: core` shared across `/events`, `/users/*`, `/repos/*`; `Link` header `rel="last"` page=3 at `per_page=100` |
| 3 | **Enrichment declared bounded best-effort sampling** with a budget-skip state (refined by Appendices B–D). | One live page: ~92–95 PushEvents, ~89 distinct actors, ~92 distinct repos ≈ 181 cold entity requests/page ≈ 2,172/hr at default cadence vs 40/hr supply ≈ 1.8% theoretical cold coverage |
| 4 | **Enrichment state moved from `push_events` to entity tables, with stub upserts in the ingest transaction.** | Review verdict (upheld): shape defect on V1 Section 7’s seven per-event enrichment columns |
| 5 | **Stack decisions pinned (Section 2A).** V1 named no versions, job backend, HTTP client, test tooling, recurring-poll mechanism, or compose topology. | Verified absence in V1 |
| 6 | **Post-commit enqueue + reconciler kept** (critique refuted). | Solid Queue defaults to a separate queue database and documents `enqueue_after_transaction_commit` |
| 7 | **Adapter/registry design kept** (speculation critique refuted): fixture implementations ship in PR 4. | Review verdict: refuted |
| 8 | **Fixture mode extended to the transport layer** so enrichment is also offline. | V1’s seam left the “deterministic” demo spending live quota (~181 calls/page ≈ 3× hourly budget) |
| 9 | **Dedup demo moved to fixture replay.** | Probe-dated observations showed little or no overlap between consecutive polls |
| 10 | **One-shot `ingest` contention contract defined.** | V1 had no interaction contract while its verification script runs both concurrently |
| 11 | **Boot/test sequencing specified in PR 2.** | Verified absence in V1 of any migration/readiness/test-DB mechanics |
| 12 | **Durable quarantine; `NOT NULL` + `ON CONFLICT` semantics; `head_sha`/`before_sha` rename** with assignment names kept at the API layer. | V1 handled malformed data in logs only; PG keywords appendix confirms no legality issue — readability rename |
| 13 | **`jsonb` retention documented as semantic, not byte-exact.** | PostgreSQL datatype documentation |
| 14 | **API facts pinned: 30-day retention, 30s–6h latency, post-2025-10-07 payload** (five required fields, commits removed) — matching the assignment 1:1 (95/95 events observed). | Events docs; GitHub changelogs 2024-11-08 and 2025-08-08 |
| 15 | **Housekeeping:** Extension C explicit non-goal; descope ladder; `LOG_LEVEL`; per-HTTP request ID dropped; CI pinned; global budget table replaces per-source rate-limit columns. | Upheld findings on stale docs, log noise, and the cross-process budget gap |

**Decisions made during the review debate:** configurable budget split with poll-priority defaults; full 12-PR scope retained (with the descope ladder as insurance); Solid Queue; entity-level enrichment state with stub rows.

## Appendix B — Corrections from independent validation (2026-07-29)

A second, independent validation pass approved the direction and required these corrections. All are incorporated above (items 1–4 further refined by Appendices C–D).

| # | Correction | Where |
|---|---|---|
| 1 | Budget ledger made **class-aware** with transactional reservation, failure-stays-spent, monotonic reconciliation, shared-IP caveat | Sections 7, 10, 6 |
| 2 | Poll scheduling decomposed (cadence vs server floor vs deferrals) | Section 9 |
| 3 | `--force` restricted to cadence + stored ETag | Section 9 |
| 4 | Global live-request gate (serial outbound concurrency of one) | Sections 2A, 5, 10 |
| 5 | Enrichment state machine completed with reactivation rule and labeled coverage metrics | Sections 7, 10, 11 |
| 6 | Stub upsert merge rules; reconciler partial index matches the real predicate | Section 7 |
| 7 | Quarantine keyed by SHA-256 payload fingerprint; malformed-event taxonomy | Section 7 |
| 8 | Fixture source vs transport resolved; fail-closed; VCR rationale reworded | Sections 2A, 5, 6, 12 |
| 9 | PR ladder rebalanced (superseded by Appendix C’s dependency-ordered version) | Section 13 |
| 10 | Protocol headers pinned; SSRF boundary; `Link` pagination explicit | Sections 2A, 9, 10 |
| 11 | “Transactional outbox” → outbox-style recovery terminology | Sections 2A, 8, 14 |
| 12 | `run_id` restored; V2 authoritative in README; submission checklist; tolerant parsing; precise 304 wording | Sections 7, 11, 13, 14, 16 |

Version facts verified 2026-07-29: GitHub REST API versions `2022-11-28` (default; supported until 2028-03-10) and `2026-03-10` (latest); plan pins `2022-11-28` (probe evidence gathered under it). Rails current release: 8.1.3 (2026-03-24).

## Appendix C — Corrections from the implementation-readiness re-check (2026-07-29)

A third review round conditionally approved V2 and required eight substantive corrections plus smaller ones. All are incorporated above (locking and blocking further refined by Appendix D).

| # | Correction | Where |
|---|---|---|
| 1 | Source ownership moved from `FOR UPDATE SKIP LOCKED` row claims to **session-level advisory locks** (row locks end at transaction end; `SKIP LOCKED` never waits) | Sections 2A, 5, 8, 9 |
| 2 | `reset_at` removed from routine scheduling; blocking timestamp added; scheduling components persisted separately | Sections 7, 9, 10 |
| 3 | **Compose profiles** for `ingest`/`test` + one-shot `setup` service (unprofiled services all start on `up`; concurrent `db:prepare` raced) | Section 2A |
| 4 | **PR order made dependency-consistent** (gate + ledger cores in PR 4, before budget-spending PRs) | Section 13 |
| 5 | **Enrichment fairness shares** with borrowing; per-class `/status`; pinned eligibility/TTL envs | Sections 7, 10, 11 |
| 6 | **Stop-on-known-event removed for the live source; ETag scoped to page 1**; overlap claim softened to probe-dated observation | Sections 9, 12, 15 |
| 7 | **One authoritative allowance formula** with startup validation; “request-attempt” naming; fresh-install bootstrap concept | Sections 7, 10 |
| 8 | **Schema completed**: actor `display_login`/`name` + envelope mappings; repo `full_name` mapping; typed columns; canonical fingerprint + occurrence counting | Section 7 |
| 9 | Smaller: exact Ruby pin; source-vs-entity error classification; tightened SSRF; `/health` live/ready split; `/status` read-only; one-shot state summary; file locations; post-merge verification gate; precise impossibility wording | Sections 2A, 9, 10, 11, 13, 14, 16 |

## Appendix D — Corrections from the freeze-readiness pass (2026-07-29)

A fourth review round validated the external facts (GitHub, Rails, Ruby, Solid Queue, PostgreSQL advisory locks, Compose semantics) and required seven implementation-level corrections plus precision edits before freezing. All are incorporated above.

| # | Correction | Why | Where |
|---|---|---|---|
| 1 | **Source lock separated from the request executor**: polling path takes `SourceLock` then the gate; enrichment takes only the gate; lock-order invariant stated; advisory keys namespaced `(SOURCE_LOCK, id)` / `(REQUEST_GATE, 1)` | Enrichment requests belong to no event source — routing them through a source lock was wrong; unnamespaced keys risk collisions | Sections 2A, 5, 8, 10 |
| 2 | **Global vs class blocking split**: `global_blocked_until` stores only truly global conditions (primary exhaustion, reserve reached, secondary limits); class blocking derived from counters (`poll_used >= poll_allowance ? reset_at : nil`); separate `effective_enrichment_time`; **secondary limits block globally** (they can arise on enrichment requests, which have no source row) | One timestamp could not defer “only that class”: enrichment exhaustion would have stopped polling and vice versa — a direct contradiction in the C-round text | Sections 7, 9, 10 |
| 3 | **Bootstrap = the first real poll of every window**, not an extra discovery request: window lifecycle (`uninitialized → active → globally_blocked`), counters reset per window, enrichment ineligible until initialized from authoritative headers | An extra quota-discovery request wastes budget; per-window (not just fresh-install) matters because IP co-tenants may spend immediately after each reset | Sections 7, 10 |
| 4 | **Docker restart policies added** (`unless-stopped` for `db`/`web`/`worker`, `stop_grace_period: 30s` on worker, `no` for one-shots), with the recovery runbook later corrected by Appendix E's API-stop/process-crash distinction | Docker’s default restart policy is `no` — the durability story silently assumed restarts that would never happen | Sections 2A, 8, 15, 16 |
| 5 | **Entity activity gated on distinct events**: `last_seen_at`/`latest_event_at`/reactivation update only when `INSERT … RETURNING id` produces a row; duplicate replays may refresh identity fields but never reactivate | “Every observed event updates `last_seen_at`” let a replayed duplicate resurrect a `skipped_budget` entity with no new activity | Sections 5, 7, 8, 12 |
| 6 | **SHA columns widened to `varchar(64)`** accepting 40- or 64-char hex | Git object names are 40 hex (SHA-1) or 64 hex (SHA-256); hard-coding 40 contradicted the tolerant-parser goal | Section 7 |
| 7 | **Quarantine identity made unambiguous**: `payload_fingerprint` is the sole unique key (`github_event_id` indexed, not unique); one canonicalization definition (SHA-256 of compact UTF-8 JSON with recursively sorted keys) | Dual unique keys left an unhandled conflict path (same event ID, different malformed payload); “or equivalently normalized `jsonb`” specified two algorithms | Section 7 |
| 8 | Precision edits: `ingest` depends on `setup`, `test` depends only on `db` and self-prepares; **Ruby switched to 3.4.10** (3.3 is security-maintenance-only — weaker greenfield signal; 3.4.10 verified current, released 2026-06-30); “Rails 8 bundles Solid Queue” reworded to “default Active Job backend in new Rails 8 applications”; `X-RateLimit-Resource` added to processed headers with a `core` verification; fairness rounding defined (floor/remainder); borrowing requires no *currently eligible* candidate; operational defaults pinned (HTTP timeouts, retries, redirects, lock wait); `/status` coverage formulas defined | Accuracy and reviewer experience | Sections 2A, 10, 11 |

## Appendix E — Execution summary (2026-07-31)

Sections 1–17 and Appendices A–D preserve the frozen architecture from 2026-07-29. A
2026-07-31 hardening amendment narrows Section 8's guarantee wording and pre-commit recovery
claim without changing behavior or architecture. This appendix records that clarification
and the implementation deltas required by Section 14.

The plan held. Every P0 story and extension shipped, no descope rung was used, and the
executor chain, lock-order invariant, class-aware ledger, event uniqueness constraint, and
distinct-event activity gate are what was frozen. What follows is the delta, and most of it
is the plan meeting a fact it could not have known in advance.

| What the plan said | What was built | Why | Record |
|---|---|---|---|
| Section 8 used a broad persisted-outcome equivalence and implied every uncommitted event would return on the next poll | The documented guarantee is limited to one `push_events` row per GitHub event ID and no activity/reactivation from duplicate observations; pre-commit recovery depends on the event remaining in a later sliding-feed response | Quarantine counters, run summaries, budget debits, executions, and logs may repeat, while the upstream window can advance past an uncommitted event. The old shorthand overstated both persistence and source-delivery guarantees; this is a wording correction, not an architecture change | ADR 0005; Section 8 amendment |
| Section 16 gates on “plain `docker compose up --build` starts exactly `db`, `setup`, `web`, `worker`” | `web` and `worker` no longer declare a `build:`; `setup` builds the shared image and they wait on it, while the `tools` one-shots keep their own build plus `pull_policy: build` | **The clean-checkout verification found the gate was false.** Compose Bake — on by default in Docker Desktop — makes every service with a `build:` its own bake target, and targets exporting the same `image:` tag race. From a cold image the reviewer's first command failed with `image "github-push-ingestor-app:latest": already exists` and started **zero** containers. It reproduces only when the image is absent, so every prior run on a warm machine passed. This is the defect the deliverable exists to catch | `docker-compose.yml`, `spec/docker_compose_spec.rb` |
| Section 15 step 8 originally treated `docker kill` as restart-policy verification | `script/verify_recovery.sh` performs **both** the documented API stop and a host-PID-namespace main-process crash, and reports both outcomes separately | `docker kill` is an API stop, and `restart: unless-stopped` skips a container the daemon recorded as manually stopped. Only the independently observed process-crash path exercises automatic restart; substituting that path without recording the distinction would hide the original defect | [`docs/evidence/2026-07-31-container-kill-recovery.md`](docs/evidence/2026-07-31-container-kill-recovery.md), README “Crash recovery verification” |
| `ENABLED_LIVE_SOURCE_COUNT` is the allowance formula's source-count input | Demoted to a **fallback**. The formula counts enabled, in-service `event_sources` rows of the running mode at window initialization and rollover, and logs `budget.source_allocation_drift` when the two disagree | A configured count that drifts from the table silently mis-sizes every allowance. Boot validation still reads no database, so the refuse-to-boot check is unchanged | ADR 0009 |
| Secondary-limit backoff is “≥ 1 minute with exponential backoff when `Retry-After` is absent” | A persisted `github_api_budget.consecutive_secondary_limits` counter escalates 60 → 120 → 240s capped at one hour, **survives window rollover**, and is cleared by one clean response | Secondary limits are IP-scoped, not window-scoped. A counter that reset with the window would restart the ladder at 60s every hour against a limit that had not relented | ADR 0010 |
| Section 10's fairness ladder covers the pending pool | The **TTL-refresh pool** allocates by the same prefer-then-borrow steps as the pending pool | The ladder was specified for pending candidates only, which left the refresh pool able to starve one class. Found by reading merged code against the plan rather than by a failing test | ADR 0010 |
| PR ladder order in Section 13 | PR 10 merged before PR 9 (`5454dda` before `6b57add`), and an “Extension A completion” commit (`687fdc3`) shipped work with no slot in the ladder | The ladder's *dependency* order held — nothing spent budget before the gate and ledger landed in PR 4. The merge order did not, and the Extension A completion closed two items the ladder had assumed were finished | Git history |
| Section 14 names eight ADR topics | Twelve ADRs shipped | The ledger topic split across three records (0004 allowance formula, 0007 fairness and borrowing, 0010 secondary-limit escalation) because they are separately contestable decisions. Two more (0006 decomposed poll state, 0009 runtime source allocation) were decisions the plan did not anticipate needing | [`docs/adr/`](docs/adr/) |
| ADRs are written alongside the code they describe | ADR 0011 (pinned API version) and ADR 0012 (Solid Queue over Kafka) were written in PR 12 | Both are Section 14 deliverables that no implementation PR owned, because neither records a decision made *during* a PR — they record decisions made before PR 1 and never written down. PR 12 is the last opportunity, and Section 16 forbids a plan that points at documents which do not exist | ADR 0011, ADR 0012 |
| The plan is the reviewer's architecture document until the brief exists | [`docs/DESIGN_BRIEF.md`](docs/DESIGN_BRIEF.md) is the reviewer's entry point; this plan is the internal execution and traceability artifact | As Section 14 intended. Stated here because the README's pointer changed with it | README “Development” |

Two things worth stating after hardening:

- **Guarantee wording now names only proved invariants.** Broad outcome shorthand was removed; any reference to exactly-once behavior or complete capture/enrichment is a negation or limitation.
- **The 304 finding survived first-party re-verification.** PR 6's required gate re-ran the probe under `X-GitHub-Api-Version: 2022-11-28` and committed a dated transcript; `x-ratelimit-used` incremented across an unauthenticated `304`, exactly as the review-supplied evidence in Appendix A had reported. The budget arithmetic that rests on it did not have to change.
