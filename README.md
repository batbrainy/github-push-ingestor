# github-push-ingestor

Fault-tolerant Rails service for ingesting, enriching, and persisting GitHub
Push events.

Polls GitHub's public Events API, processes `PushEvent` records, retains raw and
structured data in PostgreSQL, enriches actors and repositories within an
explicit unauthenticated request budget, and recovers cleanly from application
and worker crashes.

## Status

Poll budget and scheduling stage (PR 6). The Rails 8.1 API, PostgreSQL, Docker
Compose topology, health endpoints, and structured JSON logging landed in PR 2; the
seven core tables and their idempotent write paths in PR 3; the chain every GitHub
request flows through — request gate, class-aware budget ledger, SSRF URL policy,
live and offline transports, fixture corpus, per-source advisory lock, event-source
adapter — in PR 4; the processor registry, the tolerant `PushEvent` parser, the
quarantine taxonomy, the ingest transaction, and the one-shot command in PR 5.

This stage makes a poll a **scheduled** act rather than an unconditional one. It
adds `Link`-header pagination bounded by `MAX_PAGES_PER_POLL` and by the budget
ledger, the page-one ETag and its conditional request, the five independent
components behind `effective_poll_time`, `global_blocked_until` for the three
conditions that must stop every live request, class blocking derived from the
ledger's counters, and `Retry-After` handling for secondary limits. `--force` now
does exactly what plan §9 says it does, and nothing else.

**Nothing fires the schedule yet.** The cadence is real, but
`docker compose run --rm ingest` is still the only thing that polls; the always-on
`worker` container and its recurring task are PR 8. A one-shot run that is not yet
due now reports the instant it becomes due instead of polling. Enrichment — filling
in actor and repository details — is PR 7, so entities are persisted as stubs
marked `pending`.

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
docker compose run --rm ingest                       # one cycle against live GitHub, if one is due
docker compose run --rm ingest --force               # ignore the cadence and the stored ETag
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
Next poll due:                    2026-07-30T14:39:12Z
Budget remaining (core):          59 (window resets 2026-07-30T15:34:12Z)
Global block:                     none
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
| `0` | Ran, or deferred: not yet due, source busy, poll allowance spent, request gate held, a global block in force, or GitHub reported a rate limit |
| `1` | The attempt failed — a transport failure, a non-success status after retries, or an unusable response body |
| `2` | Refused to run: an unknown option, a configuration the process must not run with, or a gap in the fixture corpus |

A deferred run names the instant it becomes due, and which of plan §9's five
constraints is holding it:

```text
Ingestion deferred until 2026-07-30T15:05:00Z — cadence_due_at
```

### What `--force` does, and what it does not

`--force` bypasses **the configured poll cadence and the stored ETag, and nothing
else** (plan §9). It does not bypass the source lock, GitHub's `X-Poll-Interval`
floor, this source's own backoff, a global block, the poll class allowance, or the
reserve — so a forced run can neither overspend the hourly budget nor poll faster
than GitHub asks. It also omits `If-None-Match`, which is why a forced run can
return a fresh `200` where an unforced one would have taken a `304`.

The observable difference: without `--force`, a second run inside the cadence
window prints `Ingestion deferred until … — cadence_due_at` and makes no request at
all. With `--force`, it polls — and spends one of the twelve hourly poll attempts
to do it.

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

Run it again straight away and it does not poll at all — the first run set a cadence
five minutes out, so the second reports
`Ingestion deferred until … — cadence_due_at` and makes no request.

To replay the page you need `--force`, and you need to wait about a minute:

```bash
sleep 60   # GitHub's X-Poll-Interval floor, which --force deliberately does not bypass
GITHUB_MODE=fixture docker compose run --rm ingest --force
```

That wait is the demonstration, not an inconvenience. The corpus sends
`x-poll-interval: 60` exactly as GitHub does, so the first run stored a server floor
one minute out — and `--force` obeys it, reporting
`Ingestion deferred until … — poll_floor_until` if you skip the wait. `--force`
bypasses this application's cadence, never GitHub's floor.

Once past it, nothing is created: the same page is absorbed as **4 duplicates**, the
three quarantine rows stay three rows with their occurrence counts at 2, and no
entity's activity moves. Re-running ingestion is safe at any frequency — see
[ADR 0005](docs/adr/0005-at-least-once-with-idempotent-writes.md).

### Pagination, offline

The corpus also scripts a multi-page walk, so `Link`-driven pagination and its stop
conditions are reproducible with no network:

```bash
GITHUB_MODE=fixture GITHUB_FIXTURE_SCENARIO=paginated MAX_PAGES_PER_POLL=3 \
  docker compose run --rm ingest
```

```text
Pages fetched:                    3
Events seen:                      11
Push events created:              6
Duplicates skipped:               1
Events quarantined:               3
```

Two things that look like accidents and are not. **The single duplicate is
deliberate**: page 2 repeats page 1's first event, which is how the corpus proves
plan §9's rule that every fetched page is processed in full and `github_event_id`
uniqueness absorbs the overlap — there is no stop-on-known-event, because
documented event latency is 30 seconds to 6 hours and a delayed event can surface
beside one already seen. And **raising the cap is not free**: at
`MAX_PAGES_PER_POLL=3` the poll allowance becomes 12 × 3 = 36 attempts an hour and
enrichment drops from 40 to 60 − 8 − 36 = 16. That is plan §9's "raising it trades
enrichment allowance for capture depth", as arithmetic.

At `MAX_PAGES_PER_POLL=2` the counts are identical except `Pages fetched: 2` — page
3 is empty — and the stop reason on the `ingestion.pagination_stopped` debug line
changes from `empty_page` to `page_cap`.

### Why a `304` costs a request here

GitHub's events documentation states generally that `304` responses do not count
against the rate limit; its REST best-practices documentation scopes that exemption
to requests "correctly authorized with an `Authorization` header". This service
sends no token, so the two statements disagree about exactly the population of
requests it makes. A dated unauthenticated probe run under
`X-GitHub-Api-Version: 2022-11-28` settles it for this configuration:
`x-ratelimit-used` increments across a `304`. The transcript, with complete
before-and-after headers and its own stated limits, is
[`docs/evidence/2026-07-30-unauthenticated-304-quota-probe.md`](docs/evidence/2026-07-30-unauthenticated-304-quota-probe.md).

So the ledger debits every outbound attempt, `304`s included, and the stored ETag
is a bandwidth and correctness measure rather than a quota saver. The asymmetry
justifies the choice: budgeting a `304` that turns out to be free wastes one
attempt, while not budgeting one that is in fact charged overruns a sixty-request
hour. The transcript claims nothing about authenticated requests — this project has
no token and cannot test that case.

### Expected time before records appear

A push reaches the public feed with a documented latency of 30 seconds to 6 hours,
and the default cadence polls every 5 minutes, so a given push may take hours to
appear — or never, if it left the feed's 300-event window before a poll reached it.
The feed retains 30 days. At `MAX_PAGES_PER_POLL=1` each poll sees at most the
newest ~100 events, and the feed moves considerably faster than that. **This service
samples the public feed rather than mirroring it**, and pagination deepens a single
poll within the budget rather than backfilling: events that rolled out of the window
while the service was down are not recoverable.

### Recovering from a fixture rate-limit run

The budget ledger is persisted and the corpus's rate-limit scenarios carry a real
one-hour reset, so a single exploratory run leaves a genuine global block behind:

```bash
GITHUB_MODE=fixture GITHUB_FIXTURE_SCENARIO=rate_limited docker compose run --rm ingest
```

Every later request — in any scenario — is then deferred with `globally_blocked`
until that hour elapses, and the `budget.global_block_set` log line names the
instant. To clear it in development:

```bash
docker compose exec db psql -U postgres -d github_push_ingestor_development -c "
  UPDATE github_api_budget
     SET global_blocked_until = NULL, reset_at = NULL, remaining = NULL,
         window_status = 'uninitialized'
   WHERE id = 1;"
```

### What a run logs

At the default level (plan §11): `ingestion.run_started`,
`ingestion.event_quarantined` — one per malformed event, carrying its GitHub event
ID, classification and fingerprint — `ingestion.not_due` when a poll was not
attempted, `ingestion.deferred` when GitHub or the ledger declined one,
`ingestion.run_completed` with every count and the next poll instant, and the budget
transitions `budget.window_initialized`, `budget.window_rolled`,
`budget.class_exhausted`, `budget.global_block_set` and
`budget.global_block_cleared`.

`LOG_LEVEL=debug` adds `github.request`, `ingestion.page_fetched` and
`ingestion.page_processed` per page, `ingestion.pagination_stopped` with its reason,
`ingestion.not_modified` — which carries the `x-ratelimit-used` and
`x-ratelimit-remaining` that make the `304` accounting visible in the running
system — plus a line per persisted, duplicate and ignored event.

Every line carries the run's `run_id`, except `ingestion.not_due`: a poll the
schedule turned away opens no run, so it reports `event_source_id` instead.

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
| `POLL_INTERVAL_SECONDS` | `300` | The poll cadence, and an allowance-formula input. A source polled at T is due again at T + this; an unforced run before then is deferred rather than made. Nothing fires the cadence automatically until PR 8 (plan §9, §10) |
| `MAX_PAGES_PER_POLL` | `1` | How many `Link`-followed pages one poll may fetch, and an allowance-formula input. Raising it trades enrichment allowance for capture depth: at `3` the poll allowance becomes 36 attempts an hour and enrichment drops to 16 (plan §9, §10) |
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
IngestionRunner ──► SourceLock ──► PollSchedule (due? — five components, §9)
                                 │
                                 ├──► PageLoop ──► RequestExecutor ──► RequestGate
[enrichment]  ───────────────────┘      │ ▲                        ──► BudgetLedger.reserve!
                                        │ │                        ──► UrlPolicy
                                        │ └── LinkHeader.next_url  ──► Transport (Faraday | Fixture)
                                        │                                   │
                                        │                                   ▼
                                        │                  PageWriter: one transaction per event
                                        │                  stub upserts → INSERT … ON CONFLICT
                                        │                  DO NOTHING RETURNING id → activity
                                        │                  updates only when a row returned
                                        ▼
                              RateLimitPolicy ──► BudgetLedger#block_globally!
                                        │
                                        ▼
                              PollState: the event_sources write
```

- **`Github::IngestionRunner`** owns one polling operation: it holds the source lock
  across the whole cycle, decides *inside* that lock whether a poll is due at all, opens
  the `ingestion_runs` row only if one is, and fetches with no transaction open — a
  database transaction must never span network I/O. A poll it turns away writes nothing:
  a run row exists if and only if the process tried to reach GitHub.
- **`Github::PollSchedule`** is §9's rule as a value — the maximum of `cadence_due_at`,
  `poll_floor_until`, `retry_not_before_at`, `global_blocked_until` and a derived
  `poll_class_blocked_until`. Five independent components rather than one collapsed
  timestamp, so `--force` can drop exactly one of them and a routine `X-RateLimit-Reset`
  cannot defer every poll to the top of the hour ([ADR 0006](docs/adr/0006-decomposed-poll-deferral-state.md)).
- **`Github::Ingestion::PageLoop`** follows `rel="next"` until the page cap, a denied
  reservation, an absent `Link`, or an empty page — and never because it recognised an
  event. Each page's events are written before the next is fetched, so no transaction is
  ever open across a request.
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
  spending an extra request to discover the quota. It is also the only writer of
  `global_blocked_until`, which only ever moves later.
- **`Github::RateLimitPolicy`** decides *which* response warrants a global block and until
  when — primary exhaustion to the reset GitHub named, a reserve breach to the same, a
  secondary limit to `Retry-After` clamped between one minute and one hour. Class
  exhaustion deliberately writes nothing there: it is derived from the counters, so
  polling running out never stops enrichment and vice versa.
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
- **`Github::Ingestion::PollState`** makes the one `event_sources` write per run, inside
  the source lock. Its rule: the scheduling components move only when a poll attempt
  actually happened, so a budget denial or a held gate can neither advance the cadence nor
  burn a healthy source's failure count.

Decisions behind this are recorded in
[`docs/adr/`](docs/adr/): advisory locks and the gate (0002), the source and transport
seams (0003), the class-aware ledger (0004), at-least-once processing with idempotent
writes (0005), and decomposed poll deferral state (0006).

## Planned contents

| Section | Lands with |
|---|---|
| Enrichment flow | PR 7 |
| Data model reference | PR 12 (design brief) |
| Continuous ingestion behavior — what the always-on poller does on a schedule | PR 8 |
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
