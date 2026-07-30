# github-push-ingestor

Fault-tolerant Rails service for ingesting, enriching, and persisting GitHub
Push events.

Polls GitHub's public Events API, processes `PushEvent` records, retains raw and
structured data in PostgreSQL, enriches actors and repositories within an
explicit unauthenticated request budget, and recovers cleanly from application
and worker crashes.

## Status

Ingestion stage (PR 5). The Rails 8.1 API, PostgreSQL, Docker Compose topology,
health endpoints, and structured JSON logging landed in PR 2; the seven core
tables and their idempotent write paths in PR 3; the chain every GitHub request
flows through — request gate, class-aware budget ledger, SSRF URL policy, live and
offline transports, fixture corpus, per-source advisory lock, event-source adapter
— in PR 4.

This stage closes the loop: **`docker compose run --rm ingest` fetches a page of
public events and persists it.** It adds the processor registry and the tolerant
`PushEvent` parser, the quarantine taxonomy with canonical fingerprints, the ingest
transaction with its stub entity upserts and distinct-event activity gating, the
ingestion-run summaries, and the one-shot command with the contention contract of
plan §9.

**Polling is still manual.** Nothing runs on a schedule yet: the cadence,
`Link`-header pagination and ETag reuse land in PR 6, and the always-on `worker`
container in PR 8. Enrichment — filling in actor and repository details — is PR 7,
so entities are persisted as stubs marked `pending`.

Ingestion capabilities land PR by PR; each README section below is completed by
the pull request that ships the capability it documents. The authoritative
execution plan is [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) — its
pre-implementation revision history lives in Git and in its Appendices A–D.
Delivery is tracked on the
[GitHub Push Ingestor Delivery project](https://github.com/users/batbrainy/projects/1).

## Requirements

- Docker with Compose v2 (`docker compose`). Nothing else is needed on the
  host — Ruby 3.4.10 and all dependencies live in the image.

## Quick start (clean checkout)

```bash
docker compose up --build
```

This starts, in dependency order (plan §2A):

1. `db` — PostgreSQL 16 with a named volume and a `pg_isready` healthcheck
2. `setup` — one-shot `bin/rails db:prepare` for **both** the primary and
   queue databases
3. `web` — the Rails API on http://localhost:3000, started only after `setup`
   completes successfully

Verify it is healthy:

```bash
curl http://localhost:3000/health/live    # {"status":"ok"} — process is up
curl http://localhost:3000/health/ready   # {"status":"ok"} — database reachable, schema current
```

Neither health endpoint ever calls GitHub or consumes request budget.

Run the test suite (isolated `*_test` databases; never touches the
development databases):

```bash
docker compose run --rm test
```

Rails and application logs (requests, and jobs from PR 8 onward) are one
structured JSON stream; PostgreSQL and Puma startup output remain their own
plain-text formats:

```bash
docker compose logs -f
```

Stop everything (add `-v` to also drop the database volume):

```bash
docker compose down
```

## One-shot ingestion

```bash
docker compose run --rm ingest                       # one cycle against live GitHub
docker compose run --rm ingest --force               # see the note below
docker compose run --rm ingest --help                # options and exit codes
GITHUB_MODE=fixture docker compose run --rm ingest   # deterministic, no network
```

It fetches the first page of `https://api.github.com/events`, processes every
event on it, and prints what it did followed by the persisted state of the system:

```text
Ingestion run 2f5b9c3e-7a41-4d0c-9b62-1c8e5f0a4d33 completed
Pages fetched:                    1
Events seen:                      8
Push events created:              4
Duplicates skipped:               0
Events quarantined:               3
Non-push events ignored:          1
Events failed:                    0

Latest successful run:            2026-07-30T14:34:12Z (run_id 2f5b9c3e-…)
Persisted push events:            4
Pending actor enrichments:        3
Pending repository enrichments:   3
Budget remaining (core):          59 (window resets 2026-07-30T15:34:12Z)
```

**The state summary prints on every path**, including the busy and failing ones —
the command always proves system state, never just its own outcome (plan §9).

The one-shot runs while the always-on poller may be live, so it has a defined
contention contract. It retries the source's advisory lock for up to
`SOURCE_LOCK_WAIT_SECONDS`, and if the lock is still held it prints
`source busy — poller cycle in progress` plus the state summary and exits **0** —
a busy system is not a failure. Its requests go through the same request gate and
budget ledger as every other process, so it can never blow the hourly budget.

| Exit | Meaning |
|---|---|
| `0` | Ran, or deferred: source busy, poll allowance spent, request gate held, or GitHub reported a rate limit |
| `1` | The attempt failed — a transport failure, a non-success status after retries, or an unusable response body |
| `2` | Refused to run: an unknown option, a configuration the process must not run with, or a gap in the fixture corpus |

`--force` is accepted today and recorded on the run's log line, but it has **no
effect yet**: what plan §9 says it bypasses — the configured poll cadence and the
stored ETag — arrives with PR 6, and neither exists to bypass.

### Deterministic verification

Fixture mode resolves every request inside [`fixtures/github/`](fixtures/github/)
with no network at all, so the numbers are exact:

```bash
GITHUB_MODE=fixture docker compose run --rm ingest
```

The corpus page carries eight envelopes: four well-formed push events, one
`WatchEvent` that is ignored and counted, and three malformed events that are
quarantined under three distinct classifications — one missing `head`, one whose
`head` is not an object name, and one with no `type` at all. So a first run reports
**4 created, 3 quarantined, 1 ignored** and leaves three actors and three
repositories behind:

```bash
docker compose exec db psql -U postgres -d github_push_ingestor_development -c "
  SELECT (SELECT COUNT(*) FROM push_events)                     AS push_events,
         (SELECT COUNT(*) FROM github_actors)                   AS actors,
         (SELECT COUNT(*) FROM github_repositories)             AS repositories,
         (SELECT COUNT(*) FROM quarantined_events)              AS quarantined,
         (SELECT SUM(occurrence_count) FROM quarantined_events) AS occurrences;"
#  push_events | actors | repositories | quarantined | occurrences
#            4 |      3 |            3 |           3 |           3
```

Run it a second time and nothing is created: the same page is absorbed as **4
duplicates**, the three quarantine rows stay three rows with their occurrence
counts at 2, and no entity's activity moves. Re-running ingestion is safe at any
frequency — see [ADR 0005](docs/adr/0005-at-least-once-with-idempotent-writes.md).

### What a run logs

At the default level (plan §11): `ingestion.run_started`,
`ingestion.event_quarantined` — one per malformed event, carrying its GitHub event
ID, classification and fingerprint — and `ingestion.run_completed` with every count.
`LOG_LEVEL=debug` adds `github.request` and `ingestion.page_fetched`, plus a line
per persisted, duplicate and ignored event. Every line carries the run's `run_id`,
including the per-request ones.

## Environment variables

Compose runs with working defaults — no `.env` file is required. The template
is [`.env.example`](.env.example).

| Variable | Default | Purpose |
|---|---|---|
| `LOG_LEVEL` | `info` | JSON log verbosity: `debug` adds per-request/per-page lines (plan §11) |
| `RAILS_ENV` | `development` | Environment for the compose app services |
| `RAILS_MAX_THREADS` | `5` | Connection pool / Puma thread size |
| `GITHUB_MODE` | `live` | `live` reaches api.github.com; `fixture` resolves everything inside [`fixtures/github/`](fixtures/github/) with no network and fails closed on an unknown URL (plan §6, §12) |
| `GITHUB_FIXTURE_SCENARIO` | `default` | Which corpus scenario fixture mode plays |
| `HTTP_OPEN_TIMEOUT_SECONDS` | `5` | Connect timeout for a live request (plan §2A) |
| `HTTP_READ_TIMEOUT_SECONDS` | `15` | Read timeout for a live request (plan §2A) |
| `MAX_HTTP_RETRIES` | `2` | Retries after a 5xx or network timeout. Each retry is a fresh budget reservation (plan §10) |
| `MAX_REDIRECTS` | `2` | Redirect hops followed per request, each re-validated and separately reserved |
| `SOURCE_LOCK_WAIT_SECONDS` | `30` | How long the one-shot waits for a busy source lock; the poller attempts once (plan §9) |
| `POLL_INTERVAL_SECONDS` | `300` | Allowance-formula input; already caps how many ingestion attempts an hour the ledger grants — one-shot runs included. Obeyed as the poll *cadence* from PR 6 |
| `MAX_PAGES_PER_POLL` | `1` | Allowance-formula input. PR 5's ingestion fetches only the first page; the cap is enforced with `Link` pagination in PR 6 |
| `ENABLED_LIVE_SOURCE_COUNT` | `1` | Allowance-formula input: live sources sharing one per-IP budget |
| `RATE_LIMIT_RESERVE` | `8` | Requests per hour left deliberately unspent (plan §10) |

The last four feed the one authoritative allowance formula (plan §10):

```text
poll_attempt_allowance = ceil(3600 / POLL_INTERVAL_SECONDS)
                         x MAX_PAGES_PER_POLL x ENABLED_LIVE_SOURCE_COUNT
enrichment_allowance   = rate_limit - RATE_LIMIT_RESERVE - poll_attempt_allowance
```

With the defaults: 12 poll attempts and 40 enrichment attempts an hour, against
GitHub's unauthenticated limit of 60. **The process refuses to boot** if the
polling requirement leaves no capacity for enrichment.

There is deliberately no variable for the API host or the API version. The
allowed host is a constant in `Github::UrlPolicy`, because an environment
variable there would make the SSRF boundary a deployment setting; the API version
is pinned to `2022-11-28`, the version every live probe behind this plan was run
under.

Database connection settings (`POSTGRES_HOST`, `POSTGRES_PORT`,
`POSTGRES_USER`, `POSTGRES_PASSWORD`) are managed by the compose topology
itself and matter only when running the app outside compose.

Fairness shares and enrichment refresh TTLs arrive with PR 7.

## The request path

Every live GitHub request — polling and enrichment, from the poller, the worker, or the
one-shot — takes one chain, and nothing outside it calls GitHub
(`IMPLEMENTATION_PLAN.md` §5, §10):

```text
IngestionRunner ──► SourceLock ──┐
                                 ├──► RequestExecutor ──► RequestGate
[enrichment]  ───────────────────┘                   ──► BudgetLedger.reserve!
                                                     ──► UrlPolicy
                                                     ──► Transport (Faraday | Fixture)
                                                              │
                                                              ▼
                                             PageWriter: one transaction per event
                                             stub upserts → INSERT … ON CONFLICT
                                             DO NOTHING RETURNING id → activity
                                             updates only when a row returned
```

- **`Github::IngestionRunner`** owns one polling operation: it holds the source lock
  across the whole cycle, opens the `ingestion_runs` row inside that lock, fetches with no
  transaction open — a database transaction must never span network I/O — and hands the
  decoded page to the writer.
- **`Github::SourceLock`** is a session advisory lock owning one event source for a whole
  polling operation. Enrichment requests belong to no source and never take it. The
  lock-order invariant — source lock, then gate, never the reverse — is enforced at
  runtime, not just documented.
- **`Github::RequestGate`** is a second session advisory lock making outbound concurrency
  exactly one, application-wide. One hold wraps one HTTP attempt: retries re-acquire it
  rather than sleeping while holding it.
- **`Github::BudgetLedger`** debits before the request is issued, per class. Failures stay
  spent, reconciliation against response headers is monotonic within a rate-limit window,
  and the first poll of each window bootstraps it from authoritative headers rather than
  spending an extra request to discover the quota.
- **`Github::UrlPolicy`** is the SSRF boundary. It rebuilds every URL from validated
  components, and a URL that arrived inside a GitHub payload or a `Link` header always
  clears the full live policy first.
- **Transports** are `Faraday` (live) and `Fixture` (offline). The Faraday connection
  carries the adapter and no middleware at all — retries and redirects belong to the
  executor, because each attempt re-reserves budget and each redirect target is
  re-validated.

- **`Github::Ingestion::PageWriter`** turns one fetched page into rows, in **one
  transaction per event** — so a single malformed event can never discard the events
  persisted beside it. Quarantine writes stand outside any transaction, and entity activity
  updates happen only when the insert actually returned a row, so a re-polled page refreshes
  identity fields but registers no new activity.

Decisions behind this are recorded in
[`docs/adr/`](docs/adr/): advisory locks and the gate (0002), the source and transport
seams (0003), the class-aware ledger (0004), and at-least-once processing with idempotent
writes (0005).

## Planned contents

| Section | Lands with |
|---|---|
| Enrichment flow | PR 7 |
| Data model reference | PR 12 (design brief) |
| Continuous ingestion behavior and expected time before records appear | PR 6, 8 |
| Cadence gating and ETag reuse — when `--force` becomes observable and "deferred until T" comes from `effective_poll_time` | PR 6 |
| Rate-limit behavior: allowance formula, budget table, global-vs-class blocking, per-window bootstrap | PR 6 |
| Full fixture scenario matrix (retries, rate limits, redirects) | PR 11 |
| API and database inspection examples | PR 10, 12 |
| Crash-recovery verification (container kills) | PR 11, 12 |
| Known limitations (sampling-based enrichment, no complete-capture guarantee, shared-IP budget) | PR 12 |

## Reviewer commands

```bash
docker compose up --build                             # available now
docker compose run --rm test                          # available now (real suite; runs in CI too)
docker compose logs -f                                # available now
docker compose run --rm ingest                        # available now — one ingestion cycle
GITHUB_MODE=fixture docker compose run --rm ingest    # available now — deterministic, no network
```

## Development

AI-assisted development guidance for this repository lives in
[`CLAUDE.md`](CLAUDE.md).

Architecture decision records live under [`docs/adr/`](docs/adr/). The design
brief lands with PR 12.

## License

[MIT](LICENSE)
