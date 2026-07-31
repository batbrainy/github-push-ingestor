# github-push-ingestor

Fault-tolerant Rails service for ingesting, enriching, and persisting GitHub
Push events.

Polls GitHub's public Events API, processes `PushEvent` records, retains raw and
structured data in PostgreSQL, enriches actors and repositories within an
explicit unauthenticated request budget, and recovers cleanly from application
and worker crashes.

## Status

Background processing and recovery stage (PR 8). The Rails 8.1 API, PostgreSQL, Docker
Compose topology, health endpoints, and structured JSON logging landed in PR 2; the
seven core tables and their idempotent write paths in PR 3; the chain every GitHub
request flows through — request gate, class-aware budget ledger, SSRF URL policy,
live and offline transports, fixture corpus, per-source advisory lock, event-source
adapter — in PR 4; the processor registry, the tolerant `PushEvent` parser, the
quarantine taxonomy, the ingest transaction, and the one-shot command in PR 5;
`Link`-header pagination, the page-one ETag, the five independent components behind
`effective_poll_time`, and global-versus-class blocking in PR 6; the entity state
machine, per-class fairness with eligibility-aware borrowing, the freshness cache and
its refresh TTLs, `skipped_budget` with distinct-event reactivation, and
`effective_enrichment_time` in PR 7.

**This stage makes the system run by itself, and proves it recovers.** Solid Queue
now runs in its own `queue` database inside the same PostgreSQL container, a `worker`
container runs its supervisor, and two recurring tasks fire every 60 seconds:
`PollEventSourceJob`, which polls each source that §9's schedule says is due, and
`ReconcilePendingEnrichmentsJob`, which sweeps the committed entity rows for
enrichment work and schedules a cycle per class. A completed poll that created events
schedules enrichment immediately, after commit.

**Enrichment is bounded best-effort sampling, and says so.** Against ~2,172 cold
entity requests an hour of demand and 40 available, partial coverage is the design
rather than a shortfall — `skipped_budget` is a normal documented outcome, and
`bin/enrich` prints the per-class usage so the sampling rate is visible instead of a
mysteriously growing queue (plan §10).

**With the default `GITHUB_MODE=live`, `docker compose up` starts spending real
unauthenticated quota** — twelve poll requests an hour at the default cadence, plus
enrichment inside its allowance. That is the intended runtime behaviour (plan §2A);
`GITHUB_MODE=fixture docker compose up --build` runs the same flow entirely offline.

The processing guarantee is unchanged and stated exactly: at-least-once execution
plus idempotent writes plus unique constraints gives **effectively-once persisted
outcomes**. This system does not claim exactly-once execution — a job may run twice,
and the second run changes nothing.

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
4. `worker` — the Solid Queue supervisor, started on the same condition.
   **Continuous polling begins here**: its scheduler fires the 60-second tick, so
   the first poll happens within a minute and every 300 seconds after that.

Verify it is healthy:

```bash
curl http://localhost:3000/health/live    # {"status":"ok"} — process is up
curl http://localhost:3000/health/ready   # {"status":"ok"} — database reachable, schema current
```

See what it has actually done, and inspect what it captured:

```bash
curl -s http://localhost:3000/status | jq
curl -s 'http://localhost:3000/api/push_events?limit=5' | jq
curl -s http://localhost:3000/api/push_events/<github_event_id> | jq .data.raw_payload
```

**No endpoint on this surface ever calls GitHub or consumes request budget** (plan
§11). That is structural rather than a promise: none of these controllers holds an
executor or a transport, and `Github::BudgetLedger` is absent from all of them —
every one of its public methods writes, and `#bootstrap!` would create from a read
path the very ledger row a reservation owns. Four specs pin it, including one that
subscribes to every SQL statement a request issues and fails on any `INSERT`,
`UPDATE` or `DELETE`.

#### `GET /status`

Reports persisted state only: the poll schedule per event source (all five of §9's
components, plus which one is binding), the per-class ledger state, §11's three
enrichment coverage percentages, and the per-status entity counts.

Three conventions in the response body are worth knowing before reading one:

- **`null` is never a zero.** A counted zero prints `0`; a number that does not
  exist prints `null`. Where `null` would be ambiguous the disambiguating fact gets
  its own field — `ledger.present` separates "no ledger row yet" from "remaining is
  genuinely 0", `due_now` separates "no constraint applies" from "unknown", and
  `claimable_now` separates "work is claimable this second" from "nothing is
  waiting". An empty coverage window reports `null` percentages, not `0.0`: the
  ratio is undefined, not zero, and every denominator is published beside its ratio
  so you can check it.
- **The coverage window is measured on `created_at`** — when *this application*
  persisted the event, not GitHub's `occurred_at`. Coverage grades this
  application's enrichment pipeline, and that pipeline's own eligibility and
  freshness rules already run on this clock. The basis is published as
  `coverage.basis` so the choice is visible rather than assumed. Widen
  `ENRICHMENT_COVERAGE_WINDOW_SECONDS` when reviewing a fixture corpus that has aged.
- **`actor_requests.available` is a floor, not a ceiling.** §10 lets one class
  borrow the other's unspent capacity when the other has no eligible candidate, so a
  class does not stop at zero available. The real ceiling is the `enrichment` pair
  beside it.

`pending` in the entity counts means `enrichment_status = 'pending'` exactly. The
`candidates` figure beside it is pending **plus** `retryable_failure` — the "how much
work is left" number `bin/ingest` prints. Two questions, two names, deliberately.

#### `GET /api/push_events` and `GET /api/push_events/:id`

`:id` is the **GitHub event id**, not the surrogate primary key — the identifier §11
puts on every log line, so a log line is a URL you can type. The surrogate key
appears in no response.

Paging is keyset on `(occurred_at, id)` with an opaque cursor, not `offset`: the
poller writes continuously and this list is newest-first, so an offset page 2 would
re-serve rows from page 1 and skip others whenever a poll landed in between. Follow
`pagination.next_cursor`, or the RFC-8288 `Link: …; rel="next"` header. `limit`
defaults to 25 and is capped at 100 — a value outside that range is a `400`, never a
silent clamp, because a client that asked for 500 and received 100 cannot tell
whether it received everything. `actor_id` and `repository_id` filter; an unknown
parameter is a `400` rather than a silently unfiltered answer.

The list omits `raw_payload` — it is a multi-kilobyte TOASTed `jsonb` column nobody
scans a list for. `GET /api/push_events/:id` returns it, which is how §16's "raw
payload is retained" gate is checkable without a psql session. Every row nests its
actor and repository with their `enrichment_status`, so §16's enrichment gate is
visible in a browser as statuses flip from `pending` to `complete` while the worker
runs.

Run the test suite (isolated `*_test` databases; never touches the
development databases):

```bash
docker compose run --rm test
```

That runs `rspec` twice: the suite, and then [`spec/stress`](spec/stress/) — the threaded
budget-ledger stress specs, which open several real PostgreSQL sessions and therefore need
their own process ([`spec/stress/README.md`](spec/stress/README.md) explains why). CI runs
the same two steps.

Rails, Active Job and application logs are one structured JSON stream;
PostgreSQL and Puma startup output remain their own plain-text formats:

```bash
docker compose logs -f
docker compose logs -f worker    # the poll tick, enrichment cycles, reconciliation
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
| `0` | Ran, or deferred: not yet due, source busy, source out of service, poll allowance spent, request gate held, a global block in force, or GitHub reported a rate limit |
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
entity's activity moves — and **no skipped entity is reactivated**, which is the
half of plan §7's merge rules a re-polled window would otherwise break. Re-running
ingestion is safe at any frequency — see
[ADR 0005](docs/adr/0005-at-least-once-with-idempotent-writes.md).

### Enrichment, offline

The same corpus resolves every entity the page referenced, so the whole flow — poll,
persist, stub, enrich — runs with no network:

```bash
GITHUB_MODE=fixture docker compose run --rm ingest
GITHUB_MODE=fixture docker compose run --rm enrich --limit 6
```

Four of the six entities resolve, and two are gone. That is deliberate: corpus event
`58000000008` references an actor and a repository that both `404`, because §10
requires a dead enrichment target to fail the *entity* and leave the source running.

```bash
docker compose exec db psql -U postgres -d github_push_ingestor_development -c "
  SELECT 'actor' AS class, enrichment_status, COUNT(*) FROM github_actors GROUP BY 2
  UNION ALL
  SELECT 'repository', enrichment_status, COUNT(*) FROM github_repositories GROUP BY 2;"
#    class    | enrichment_status  | count
#  actor      | complete           |     2
#  actor      | permanent_failure  |     1
#  repository | complete           |     2
#  repository | permanent_failure  |     1
```

Six requests, split evenly, and the event source untouched by either `404`:

```bash
docker compose exec db psql -U postgres -d github_push_ingestor_development -c "
  SELECT enrichment_used, actor_share_used, repository_share_used FROM github_api_budget;
  SELECT status, enabled FROM event_sources;"
#  enrichment_used | actor_share_used | repository_share_used
#                6 |                3 |                     3
#  status | enabled
#  idle   | t
```

Run `enrich` again and it reports `Nothing to enrich — no eligible candidate`: every
entity is either enriched and inside its refresh TTL, or permanently failed. That is
the freshness cache, and it costs nothing.

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

### When a source goes out of service

A permanent `4xx` from `/events` — not a rate limit, not a `5xx`, both of which are
retried — takes the source out of service: `event_sources.status` becomes `failed`,
`last_error` records why, and **no further poll is attempted**, including under
`--force`. That is deliberate: the request cannot succeed, so retrying it on a cadence
would spend the hourly budget on a certainty.

```text
Ingestion deferred — source_failed
```

Nothing returns it to service automatically — a later success cannot, because no later
poll happens. Clear it once the cause is fixed:

```bash
docker compose exec db psql -U postgres -d github_push_ingestor_development -c "
  UPDATE event_sources SET status = 'idle', last_error = NULL WHERE status = 'failed';"
```

`enabled` is a separate switch and stays untouched: it means *an operator turned this
off*, while `status` means *the system took this out of service*.

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
`budget.class_exhausted`, `budget.share_exhausted` — once per class per window, from
the request that reached its fairness guarantee — `budget.global_block_set` and
`budget.global_block_cleared`.

Every process also logs `config.budget_resolved` at boot, carrying the formula's inputs and
the allowances and guarantees they produce, so the numbers every later budget line is read
against are in the stream before the first request.

Four warnings name a budget condition that would otherwise be invisible:
`budget.source_allocation_drift` when `ENABLED_LIVE_SOURCE_COUNT` and the `event_sources`
table disagree; `budget.allowances_clamped` when a limit GitHub reported cannot fund the
configured formula and the allowances in force are no longer the configured ones;
`budget.window_reset_in_past` when a response's reset instant has already passed, which
means this container's clock runs ahead of GitHub's and enrichment will stay ineligible
until it does not; and `config.amplification` at boot when retries and redirects multiply to
more request attempts per poll than the whole poll allowance.

Enrichment adds `enrichment.completed` and `enrichment.failed`, each carrying the
entity type, its GitHub id, the response classification, the resulting entity status
and the attempt number; `enrichment.aged_out`, one summary line per class per sweep
rather than one per row; `enrichment.reactivated` when a genuinely new push event
brings a `skipped_budget` entity back; `enrichment.lease_lost` at warning level when
an outcome arrived after another worker had claimed the row; and
`enrichment.cycle_failed` at error level when an exception escapes a cycle entirely,
carrying the lease it released and the error class.

**Every failure and every retry reaches the default level.** `github.request` is
raised to warning when the request failed — a 5xx, a network timeout, a 404 on an
entity URL, a permanent 4xx, or a URL the SSRF boundary refused — carrying the
classification, status, URL and attempt number. `github.retry_scheduled` is emitted
at info for each of the `MAX_HTTP_RETRIES` backoffs, reporting the delay actually
slept rather than a freshly jittered one. `github.retry_exhausted` is emitted at
warning when the attempts ran out, which is what distinguishes "retried and gave up"
from "failed once, permanently". Each carries the `run_id` of the poll or the entity
id of the enrichment that issued it, so a whole retry ladder greps as one trace.

On the source side, `ingestion.source_backoff` names a failed poll's own retry
instant and the delay behind it — `next_poll_at` is the maximum of §9's five
independent components and so cannot say which one is binding — and
`ingestion.source_failed` at error level reports the one transition nothing in this
application reverses: a permanent 4xx on `/events` takes the source out of service
until an operator clears it (plan §10). It shares its token with the
`deferral_reason` of every poll subsequently refused, so one grep returns the
transition and its consequences together.

`LOG_LEVEL=debug` adds the `github.request` line for requests that **succeeded** (the
failing ones are already at warning), `ingestion.page_fetched` and
`ingestion.page_processed` per page, `ingestion.pagination_stopped` with its reason,
`ingestion.not_modified` — which carries the `x-ratelimit-used` and
`x-ratelimit-remaining` that make the `304` accounting visible in the running
system — `budget.co_tenant_usage` (below), plus a line per persisted, duplicate and ignored
event.

### Sharing the outbound IP

The unauthenticated limit is keyed to the outbound IP, so anything else behind that address
spends the same sixty requests an hour. The ledger cannot prevent that — it coordinates this
application only, and converges to GitHub's headers rather than overriding them (plan §7) —
but it does report it. On every reconciliation it compares GitHub's `x-ratelimit-used`
against its own `poll_used + enrichment_used`; a positive difference is capacity this
application did not spend, and it is logged as `budget.co_tenant_usage` at debug level.
When that difference has taken `x-ratelimit-remaining` down to `RATE_LIMIT_RESERVE` the line
is raised to `budget.co_tenant_pressure` at info, because every class is about to be denied
`reserve_reached` for the rest of the window and the silence that follows otherwise has no
cause attached to it. Nothing is inferred back into the class counters: GitHub's `used`
carries no request class, and a guess would break the fairness accounting.

Every line carries the run's `run_id`, except `ingestion.not_due`: a poll the
schedule turned away opens no run, so it reports `event_source_id` instead.

Background work adds the job vocabulary: `job.completed` for every job the worker
runs — carrying `job_id`, `job_class`, `queue`, `attempt`, `duration_ms` and the
identifiers that job produced — and `job.failed` with the error class and message
when one raises. `ingestion.source_busy` reports a tick that found the source owned
by another poller, `ingestion.cycle_failed` one source that failed without stopping
the tick, and `enrichment.dispatched` is the reconciliation summary: what it
scheduled, what blocked it, and the per-class state counts and share usage. A tick
that scheduled nothing keeps that line at debug, so an exhausted window does not
emit a line a minute for the rest of the hour.

The trace is one hop: a `job_id` on `job.completed` gives the `run_id`s that job
opened, and every `ingestion.*` line carries the `run_id`.

```bash
docker compose logs worker | grep -E 'job\.(completed|failed)|enrichment\.dispatched'
```

## Environment variables

Compose runs with working defaults — no `.env` file is required. The template
is [`.env.example`](.env.example).

| Variable | Default | Purpose |
|---|---|---|
| `LOG_LEVEL` | `info` | JSON log verbosity. `info` carries the run summaries, the budget transitions and **every failure, retry and backoff**; `debug` adds the per-request and per-page lines for requests that succeeded (plan §11) |
| `RAILS_ENV` | `development` | Environment for the compose app services |
| `RAILS_MAX_THREADS` | `5` | Connection pool / Puma thread size |
| `GITHUB_MODE` | `live` | `live` reaches api.github.com; `fixture` resolves everything inside [`fixtures/github/`](fixtures/github/) with no network and fails closed on an unknown URL (plan §6, §12) |
| `GITHUB_FIXTURE_SCENARIO` | `default` | Which corpus scenario fixture mode plays |
| `HTTP_OPEN_TIMEOUT_SECONDS` | `5` | Connect timeout for a live request (plan §2A) |
| `HTTP_READ_TIMEOUT_SECONDS` | `15` | Read timeout for a live request (plan §2A) |
| `MAX_HTTP_RETRIES` | `2` | Retries after a 5xx or network timeout. Each retry is a fresh budget reservation (plan §10) |
| `MAX_REDIRECTS` | `2` | Redirect hops followed per request, each re-validated and separately reserved |
| `SOURCE_LOCK_WAIT_SECONDS` | `30` | How long the one-shot waits for a busy source lock; the poller attempts once (plan §9) |
| `POLL_INTERVAL_SECONDS` | `300` | The poll cadence, and an allowance-formula input. A source polled at T is due again at T + this; an unforced run before then is deferred rather than made. The worker's 60-second tick checks the schedule; it does not replace it (plan §9, §10) |
| `MAX_PAGES_PER_POLL` | `1` | How many `Link`-followed pages one poll may fetch, and an allowance-formula input. Raising it trades enrichment allowance for capture depth: at `3` the poll allowance becomes 36 attempts an hour and enrichment drops to 16 (plan §9, §10) |
| `ENABLED_LIVE_SOURCE_COUNT` | `1` | Allowance-formula input: live sources sharing one per-IP budget. **A fallback rather than the authority** — at window initialization and rollover the formula counts the enabled, in-service `event_sources` rows of the running mode and uses that instead, falling back to this value only when there are none yet. A disagreement is logged as `budget.source_allocation_drift` (plan §10, [ADR 0009](docs/adr/0009-runtime-source-allocation-and-shared-ip-observability.md)) |
| `RATE_LIMIT_RESERVE` | `8` | Requests per hour left deliberately unspent (plan §10) |
| `ACTOR_ENRICHMENT_SHARE` | `0.50` | How the enrichment allowance splits between actors and repositories: `floor(allowance x this)` guarantees actors, the remainder goes to repositories. A guarantee, not a cap — either class may borrow the other's unused capacity when the other has no *currently eligible* candidate. Both ends of `[0, 1]` are legal (plan §10) |
| `ENRICHMENT_ELIGIBILITY_WINDOW_SECONDS` | `3600` | How long a candidate stays worth enriching. Past it, the entity transitions to `skipped_budget` — which is what bounds the backlog — until a genuinely new push event reactivates it (plan §10, B8) |
| `ACTOR_REFRESH_TTL_SECONDS` | `86400` | How long an enriched actor is reused before it is re-fetched. Never-enriched candidates always take priority over refreshes (plan §10) |
| `REPOSITORY_REFRESH_TTL_SECONDS` | `86400` | The same, for repositories |
| `ENRICHMENT_COVERAGE_WINDOW_SECONDS` | `86400` | How far back `GET /status` looks when computing §11's three coverage percentages, measured on `push_events.created_at`. The only knob here that changes what the system *reports* rather than what it *does* |

`POLL_INTERVAL_SECONDS`, `MAX_PAGES_PER_POLL`, `ENABLED_LIVE_SOURCE_COUNT` and
`RATE_LIMIT_RESERVE` feed the one authoritative allowance formula (plan §10):

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

The enrichment allowance is then split by `ACTOR_ENRICHMENT_SHARE` (plan §10):

```text
actor_guarantee      = floor(enrichment_allowance x ACTOR_ENRICHMENT_SHARE)
repository_guarantee = enrichment_allowance - actor_guarantee
```

With the defaults: 20 actor and 20 repository attempts an hour. The remainder
always goes to repositories, because the formula floors one side and subtracts for
the other — so the two always add up to the whole allowance.

Database connection settings (`POSTGRES_HOST`, `POSTGRES_PORT`,
`POSTGRES_USER`, `POSTGRES_PASSWORD`) are managed by the compose topology
itself and matter only when running the app outside compose.

## The request path

Every live GitHub request — polling and enrichment, from the poller, the worker, or the
one-shot — takes one chain, and nothing outside it calls GitHub
(`IMPLEMENTATION_PLAN.md` §5, §10):

```text
IngestionRunner ──► SourceLock ──► PollSchedule (due? — five components, §9)
                                 │
                                 ├──► PageLoop ──► RequestExecutor ──► RequestGate
EnrichmentRunner ────────────────┘      │ ▲                        ──► BudgetLedger.reserve!
  AgeOut → skipped_budget               │ │                        ──► UrlPolicy
  Fairness → class, pool, borrow        │ └── LinkHeader.next_url  ──► Transport (Faraday | Fixture)
  Claim → lease on next_retry_at        │                                   │
  (never a SourceLock, §8 step 1)       │                                   ▼
                                        │                  PageWriter: one transaction per event
                                        │                  stub upserts → INSERT … ON CONFLICT
                                        │                  DO NOTHING RETURNING id → activity
                                        │                  updates and reactivation only when
                                        │                  a row returned
                                        ▼
                              RateLimitPolicy ──► BudgetLedger#block_globally!
                                        │
                                        ├──► PollState: the event_sources write
                                        └──► EntityState: the one entity write, lease-guarded
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
  secondary limit to `Retry-After` (either RFC 9110 form) clamped between one minute and one
  hour. When a secondary limit carries no usable `Retry-After`, the block backs off
  exponentially with jitter across *consecutive* limits — 60s, 120s, 240s, capped at one
  hour — counted in `github_api_budget.consecutive_secondary_limits`, which survives a
  window rollover because secondary limits are IP-scoped rather than window-scoped. One live
  request that completes without a secondary limit resets the run. Class exhaustion
  deliberately writes nothing there: it is derived from the counters, so polling running out
  never stops enrichment and vice versa.
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
- **`Github::EnrichmentRunner`** owns one enrichment cycle and enriches at most one
  entity: it ages overdue candidates into `skipped_budget` first — unconditionally, because
  §12's sequence needs skipping to keep happening precisely while the budget is exhausted —
  then asks fairness which class works next, leases that row, fetches through the same
  chain, and writes one outcome. It never takes a source lock and opens no transaction
  across the request.
- **`Github::Enrichment::Fairness`** applies §10's ladder: a never-enriched candidate in a
  class still inside its guarantee, then the same borrowing when the other class has no
  *currently eligible* candidate, then a TTL-stale refresh only when no pending candidate
  is eligible anywhere. The refresh pool allocates by the same two steps — prefer a class
  with room, borrow only from a class with nothing to refresh — so neither pool can starve a
  class. It decides; the ledger enforces, so a wrong answer produces a refused reservation
  rather than an overspend
  ([ADR 0007](docs/adr/0007-enrichment-fairness-shares-and-borrowing.md),
  [ADR 0010](docs/adr/0010-secondary-limit-escalation-and-refresh-pool-fairness.md)).
- **`Github::Enrichment::Claim`** prevents two workers enriching one entity by leasing the
  row — a conditional `UPDATE` that pushes `next_retry_at` forward. One column, one
  meaning: the same predicate excludes leases, backoffs and secondary-limit deferrals from
  both candidate pools and from the age-out sweep, so the four queries cannot drift apart.
  A crashed worker leaves nothing to clean up; the lease expires.
- **`Github::Enrichment::EntityState`** is §10's response behaviour resolved onto one
  entity row, and `PollState`'s twin. Its rules: an attempt is counted only for an outcome
  that says something about *this entity* — a rate limit is a fact about the IP — and a
  retryable failure never downgrades an already-enriched record, so a transient `500` on a
  refresh cannot drop coverage.
- **`Github::EnrichmentSchedule`** is §9's enrichment rule as a value: the maximum of the
  entity's `next_retry_at`, `global_blocked_until` and a derived
  `enrichment_class_blocked_until`. Three components, no `--force` — §9 licenses that
  against a poll cadence, and enrichment has none — and no per-class share, because a share
  exhaustion is a denial rather than a deferral.

Decisions behind this are recorded in
[`docs/adr/`](docs/adr/): advisory locks and the gate (0002), the source and transport
seams (0003), the class-aware ledger (0004), at-least-once processing with idempotent
writes (0005), decomposed poll deferral state (0006), enrichment fairness shares
and borrowing (0007), post-commit enqueue with entity-scoped reconciliation (0008),
runtime source allocation with shared-IP observability (0009), and secondary-limit
escalation with refresh-pool fairness (0010).

## Continuous ingestion

The `worker` container runs one Solid Queue supervisor: a dispatcher, the worker
threads from [`config/queue.yml`](config/queue.yml), and a scheduler running
[`config/recurring.yml`](config/recurring.yml). Two tasks fire every 60 seconds.

**A tick is not a poll.** `PollEventSourceJob` selects the sources whose cached
`next_poll_at` has arrived, and `Github::IngestionRunner` then re-reads each one
inside its advisory lock and applies §9's five components before spending anything.
At the default 300-second cadence roughly four ticks in five cost one indexed
`SELECT` and nothing else. The tick exists so a source that becomes due at T is
polled within a minute of T — not so that polls happen every minute, which the
allowance formula (twelve poll requests an hour, no headroom) could not pay for.
A source another process is polling is reported at INFO and left alone; the tick
never retries it, because the next tick is 60 seconds away.

**Enrichment is scheduled twice over, deliberately.** A run that created events
schedules one cycle per class as soon as its rows are committed and its advisory
lock is released. That enqueue is a *hint*: the durable record of pending work is the
entity rows themselves, so `ReconcilePendingEnrichmentsJob` sweeps them every 60
seconds and schedules a cycle for any class that has claimable work and is not
blocked by the ledger. Work committed before a crash but never enqueued is
rediscovered on the next tick — no operator step, no cleanup job, and no queue
inspection (plan §8, [ADR 0008](docs/adr/0008-post-commit-enqueue-and-entity-scoped-reconciliation.md)).

Each cycle enriches at most one entity, chosen by §10's fairness policy under a
lease, so a backlog of ninety pending actors is one queued job rather than ninety.
Steady state at the defaults: twelve polls an hour, and at most forty enrichment
requests an hour split between the two classes.

**Crashes need no cleanup.** A killed worker's PostgreSQL session dies with it, and
the source advisory lock goes with the session; its claim lease is a timestamp on
`next_retry_at` that expires by arithmetic; and any job it was running may run again,
because every write on the path is idempotent. That is at-least-once execution with
effectively-once persisted outcomes — never exactly-once execution.

## Planned contents

| Section | Lands with |
|---|---|
| Data model reference | PR 12 (design brief) |
| API and database inspection examples | PR 10, 12 |
| Known limitations (sampling-based enrichment, no complete-capture guarantee, shared-IP budget) | PR 12 |

## Reviewer commands

```bash
docker compose up --build                             # available now — starts continuous polling
docker compose run --rm test                          # available now (real suite; runs in CI too)
docker compose logs -f worker                         # available now — the tick, cycles, reconciliation
docker compose logs -f                                # available now
docker compose run --rm ingest                        # available now — one ingestion cycle
docker compose run --rm enrich --limit 6              # available now — up to six enrichment cycles
GITHUB_MODE=fixture docker compose up --build         # available now — the whole system, no network
GITHUB_MODE=fixture docker compose run --rm ingest    # available now — deterministic, no network
GITHUB_MODE=fixture docker compose run --rm enrich --limit 6
script/verify_recovery.sh --confirm                   # §15 step 8's container kills; nothing in CI runs it
```

The queue is a database, so it is inspectable with the same tool as everything else:

```bash
docker compose exec db psql -U postgres -d github_push_ingestor_queue_development \
  -c "SELECT key, class_name, schedule FROM solid_queue_recurring_tasks;" \
  -c "SELECT class_name, count(*) FROM solid_queue_jobs GROUP BY 1;" \
  -c "SELECT kind, name, last_heartbeat_at FROM solid_queue_processes;"
```

Recovery is watchable in under a minute — stop the worker, put the entities back into
`pending`, empty the queue (the crash), and start it again:

```bash
docker compose stop worker
docker compose exec db psql -U postgres -d github_push_ingestor_development \
  -c "UPDATE github_actors SET enrichment_status = 'pending', fetched_at = NULL, next_retry_at = NULL;"
docker compose exec db psql -U postgres -d github_push_ingestor_queue_development \
  -c "TRUNCATE solid_queue_jobs CASCADE;"
docker compose start worker
docker compose logs -f worker    # enrichment.dispatched, then enrichment.completed
```

## Crash recovery, verified

`IMPLEMENTATION_PLAN.md` §15 step 8 asks a reviewer to kill containers and watch them come
back. Run it with one command, against a stack started in fixture mode:

```bash
GITHUB_MODE=fixture docker compose up --build -d
script/verify_recovery.sh --confirm
```

A dated transcript of that run is committed at
[`docs/evidence/2026-07-31-container-kill-recovery.md`](docs/evidence/2026-07-31-container-kill-recovery.md).
Nothing in CI runs the script — it kills containers and writes to the development databases,
and `spec/docker_compose_spec.rb` asserts that no workflow references it.

**Read §15's command knowing what it does.** `docker kill` is an API stop: the daemon records
the container as manually stopped, and `restart: unless-stopped` is defined to skip exactly
that case. So the documented command leaves the container down, and

```bash
docker kill github-push-ingestor-worker-1
docker compose ps          # Exited (137) — and it stays that way
docker compose up -d worker
```

is the honest sequence. The restart policy is sound; it is the *kill* that does not exercise
it. A crash — the container's main process dying rather than being stopped through the API —
does, and every service recovered on its own with no operator step. The script performs both
and reports both.

One reading tip for §15 step 8's `docker compose ps` output: `web`'s container healthcheck
curls `/health/live`, which never touches the database, so `web` stays green throughout a `db`
kill. `/health/ready` is the observable that flips.

### Fixture scenario matrix

Every scenario resolves inside [`fixtures/github/`](fixtures/github/) with no network at all.
Each poll obeys GitHub's `X-Poll-Interval` floor of 60s, which `--force` deliberately does not
bypass, so allow a minute between successive ingestion scenarios.

| Scenario | Command | What it shows | Cleanup |
|---|---|---|---|
| `default` | `GITHUB_MODE=fixture docker compose run --rm ingest` | 4 push events, 3 actors, 3 repositories, 3 quarantined | none |
| `default` (replay) | `… run --rm ingest --force` after 60s | `duplicates_skipped > 0`, occurrence counts climb, no skipped entity reactivated | none |
| `default` (enrich) | `… run --rm enrich --limit 6` | both classes enrich within their fairness shares | none |
| `paginated` | `GITHUB_FIXTURE_SCENARIO=paginated MAX_PAGES_PER_POLL=3 … ingest` | `Link`-driven walk over 3 pages | none |
| `paginated_final_page` | `GITHUB_FIXTURE_SCENARIO=paginated_final_page … ingest` | the walk stops when no `next` link exists | none |
| `transient_failure` | `GITHUB_FIXTURE_SCENARIO=transient_failure … ingest` | one `500`, then success on retry | none |
| `transient_failure_exhausted` | `GITHUB_FIXTURE_SCENARIO=transient_failure_exhausted … ingest` | retries exhausted; the source backs off | source backoff |
| `redirecting_repository` | `GITHUB_FIXTURE_SCENARIO=redirecting_repository … enrich --class repository` | a renamed repository followed across one validated hop, debited twice | none |
| `hostile_redirect` | `GITHUB_FIXTURE_SCENARIO=hostile_redirect … enrich --class repository` | an off-host `Location` refused by the URL policy; the second hop is never sent and the event source stays in service | none |
| `secondary_rate_limited` | `GITHUB_FIXTURE_SCENARIO=secondary_rate_limited … ingest` | a secondary limit blocks globally | global block |
| `rate_limited` | `GITHUB_FIXTURE_SCENARIO=rate_limited … ingest` | primary exhaustion → `global_blocked_until` | **a real one-hour global block** |

The last two leave durable state behind on purpose — that is the behaviour being demonstrated.
`script/verify_recovery.sh --phase=cleanup` runs the SQL under
[Recovering from a fixture rate-limit run](#recovering-from-a-fixture-rate-limit-run), and
`--phase=rate-limit` plays the rate-limit scenario and cleans up immediately after.

## Development

AI-assisted development guidance for this repository lives in
[`CLAUDE.md`](CLAUDE.md).

Architecture decision records live under [`docs/adr/`](docs/adr/). The design
brief lands with PR 12.

## License

[MIT](LICENSE)
