# github-push-ingestor

Fault-tolerant Rails service for ingesting, enriching, and persisting GitHub
Push events.

Polls GitHub's public Events API, processes `PushEvent` records, retains raw and
structured data in PostgreSQL, enriches actors and repositories within an
explicit unauthenticated request budget, and recovers cleanly from application
and worker crashes.

## Status

Data model stage (PR 3). The Rails 8.1 API, PostgreSQL, Docker Compose topology,
health endpoints, and structured JSON logging landed in PR 2. The seven core
tables are now migrated and modelled, with the idempotent write paths
(`ON CONFLICT` inserts and stub-entity merge rules) covered by specs, and CI runs
the real RSpec suite. Nothing polls GitHub yet.

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

Database connection settings (`POSTGRES_HOST`, `POSTGRES_PORT`,
`POSTGRES_USER`, `POSTGRES_PASSWORD`) are managed by the compose topology
itself and matter only when running the app outside compose.

Budget knobs, fairness shares, refresh TTLs, and `GITHUB_MODE` arrive with
PRs 4–7.

## Planned contents

| Section | Lands with |
|---|---|
| Architecture summary | PR 4–5 |
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
