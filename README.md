# github-push-ingestor

Fault-tolerant Rails service for ingesting, enriching, and persisting GitHub
Push events.

Polls GitHub's public Events API, processes `PushEvent` records, retains raw and
structured data in PostgreSQL, enriches actors and repositories within an
explicit unauthenticated request budget, and recovers cleanly from application
and worker crashes.

## Status

Request-infrastructure stage (PR 4). The Rails 8.1 API, PostgreSQL, Docker
Compose topology, health endpoints, and structured JSON logging landed in PR 2;
the seven core tables and their idempotent write paths landed in PR 3. This stage
adds the chain every GitHub request flows through — the global request gate, the
class-aware budget ledger, the SSRF URL policy, live and offline transports, and
the static fixture corpus — plus the per-source advisory lock and the event-source
adapter contract.

**Nothing polls GitHub yet.** The infrastructure exists and is tested, but no
event source is provisioned and no code path fetches a page: ingestion lands in
PR 5 and scheduled polling in PR 6.

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
| `POLL_INTERVAL_SECONDS` | `300` | Allowance-formula input; obeyed as the poll cadence from PR 6 |
| `MAX_PAGES_PER_POLL` | `1` | Allowance-formula input; enforced as the page cap from PR 6 |
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
[polling only]  SourceLock  ──┐
                              ├──► RequestExecutor ──► RequestGate
[enrichment]  ────────────────┘                   ──► BudgetLedger.reserve!
                                                  ──► UrlPolicy
                                                  ──► Transport (Faraday | Fixture)
```

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

Decisions behind this are recorded in
[`docs/adr/`](docs/adr/): advisory locks and the gate (0002), the source and transport
seams (0003), and the class-aware ledger (0004).

## Planned contents

| Section | Lands with |
|---|---|
| Ingestion and enrichment flow | PR 5, 7 |
| Data model reference | PR 12 (design brief) |
| One-shot ingestion command (default, `--force`, deferred/busy semantics) | PR 5 |
| Continuous ingestion behavior and expected time before records appear | PR 6, 8 |
| Rate-limit behavior: allowance formula, budget table, global-vs-class blocking, per-window bootstrap | PR 6 |
| Deterministic fixture verification with exact expected counts | PR 11 |
| Log, API, and database inspection examples | PR 10, 12 |
| Crash-recovery verification (container kills) | PR 11, 12 |
| Known limitations (sampling-based enrichment, no complete-capture guarantee, shared-IP budget) | PR 12 |

## Reviewer commands

```bash
docker compose up --build        # available now
docker compose run --rm test     # available now (real suite; runs in CI too)
docker compose logs -f           # available now
docker compose run --rm ingest   # PR 5
```

## Development

AI-assisted development guidance for this repository lives in
[`CLAUDE.md`](CLAUDE.md).

Architecture decision records live under [`docs/adr/`](docs/adr/). The design
brief lands with PR 12.

## License

[MIT](LICENSE)
