# github-push-ingestor

## New here? Start with the offline demo

This program regularly checks GitHub's public activity feed, saves public code-push
events, and lets you inspect who pushed to which repository. The offline demo uses
prerecorded GitHub responses, makes no internet requests, and walks through the complete
collect → save → enrich → inspect flow in a few minutes.

```bash
GITHUB_MODE=fixture docker compose up --build -d db setup web
GITHUB_MODE=fixture docker compose run --rm ingest
GITHUB_MODE=fixture docker compose run --rm enrich --limit 6
curl -s http://localhost:3000/api/push_events
```

On a fresh project database, ingestion saves **4 valid push events**, quarantines **3
malformed events**, and ignores **1 event that is not a push**. Enrichment then attempts all
**6 actor/repository backlog rows**: **4 complete successfully**, while **2 intentional
`404` outcomes** become permanent failures for a deleted user and repository. Nothing in
this walkthrough contacts GitHub or consumes real API quota.

Already used this project and seeing different totals or a deferred poll? The database is
preserved between runs. Follow [Deterministic fixture verification](#deterministic-fixture-verification)
for the clean-reset walkthrough and expected output. When you are ready for the complete
automatic service, continue to [Quick start](#quick-start).

Fault-tolerant Rails service for ingesting, enriching, and persisting GitHub
Push events.

Polls GitHub's public Events API, processes `PushEvent` records, retains raw and
structured data in PostgreSQL, enriches actors and repositories within an
explicit unauthenticated request budget, and recovers cleanly from application
and worker crashes.

## Contents

- [What this is](#what-this-is)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [How to verify it's working](#how-to-verify-its-working)
- [One-shot ingestion](#one-shot-ingestion)
- [Deterministic fixture verification](#deterministic-fixture-verification)
- [Inspecting the data](#inspecting-the-data)
- [The data model](#the-data-model)
- [Logs](#logs)
- [Rate limits and the request budget](#rate-limits-and-the-request-budget)
- [Configuration](#configuration)
- [Architecture](#architecture)
- [Continuous ingestion](#continuous-ingestion)
- [Processing guarantees](#processing-guarantees)
- [Crash recovery verification](#crash-recovery-verification)
- [Troubleshooting and reset](#troubleshooting-and-reset)
- [Known limitations](#known-limitations)
- [Development](#development)
- [License](#license)

## What this is

GitHub publishes a firehose of public activity at `/events`. This service ingests the
`PushEvent` slice of it durably, enriches the actors and repositories those events
reference, and survives restarts — **without a token**, inside an unauthenticated ceiling
of 60 requests per hour keyed to the outbound IP.

What it does, running:

- **Polls** one event source on a cadence, following `Link`-header pagination, and
  processes every fetched page in full.
- **Persists** each `PushEvent` with typed columns and its raw `jsonb` payload, quarantining
  malformed envelopes durably instead of dropping them or failing the batch.
- **Enriches** actors and repositories through the same budget-governed request chain,
  under per-class fairness guarantees.
- **Recovers** on its own: advisory locks die with their session, entity leases expire by
  arithmetic, and a 60-second reconciler rebuilds pending work from committed rows.

**Enrichment is a durable, quota-paced backlog.** With the defaults, the hourly ledger
reserves 12 requests for polling, 40 for the enrichment class, and 8 as a safety reserve.
Durable backlog work has priority over refreshes within those 40 attempts. Actors and
repositories receive 20/20 guarantees with borrowing. Entity rows remain actionable until
enrichment succeeds or an entity-specific terminal outcome is established; quota exhaustion
only defers them to a later window. Selection remains FIFO, oldest-first within each class,
and delay never becomes a terminal outcome. See [Known
limitations](#known-limitations) for what happens when arrivals outpace that service rate.

**With the default `GITHUB_MODE=live`, `docker compose up` starts spending real
unauthenticated quota** — twelve poll requests an hour at the default cadence, plus
enrichment inside its allowance. That is the intended runtime behaviour (plan §2A);
`GITHUB_MODE=fixture docker compose up --build` runs the same flow entirely offline.

Poll observations and job deliveries may repeat. The proven write invariant is narrower:
observing the same valid event again cannot add another `push_events` row or register new
entity activity. Executions, ingestion-run rows, quarantine occurrence
counters, budget use, and logs may repeat. This system does not claim exactly-once execution. See
[Processing guarantees](#processing-guarantees).

[`docs/DESIGN_BRIEF.md`](docs/DESIGN_BRIEF.md) is the two-page architecture summary and the
best place to start. The authoritative execution plan is
[`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) — its pre-implementation revision history
lives in Git and in its Appendices A–D, and Appendix E records how the build diverged from
it. Appendix F records the durable-enrichment-backlog correction. Delivery is tracked on the
[GitHub Push Ingestor Delivery project](https://github.com/users/batbrainy/projects/1).

## Requirements

- Docker with Compose v2 (`docker compose`). Nothing else is needed on the
  host — Ruby 3.4.10 and all dependencies live in the image.

## Quick start

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
   **Continuous polling begins here**: its scheduler nominally fires every 60 seconds;
   due sources are considered on the next successful tick, subject to worker availability.

Those four are the whole stack. `ingest`, `enrich`, and `test` sit behind a compose
profile, so a plain `up` never starts them.

Verify it is healthy:

```bash
curl http://localhost:3000/health/live    # {"status":"ok"} — process is up
curl http://localhost:3000/health/ready   # {"status":"ok"} — database reachable, schema current
```

**No endpoint on this surface ever calls GitHub or consumes request budget** (plan
§11). That is structural rather than a promise: none of these controllers holds an
executor or a transport, and `Github::BudgetLedger` is absent from all of them —
every one of its public methods writes, and `#bootstrap!` would create from a read
path the very ledger row a reservation owns. Specs pin it, including ones that
subscribe to every SQL statement a request issues and fail on any `INSERT`,
`UPDATE` or `DELETE`.

Run the test suite (isolated `*_test` databases; never touches the
development databases):

```bash
docker compose run --rm --build test
```

That runs `rspec` twice: the suite, and then [`spec/stress`](spec/stress/) — the threaded
budget-ledger stress specs, which open several real PostgreSQL sessions and therefore need
their own process ([`spec/stress/README.md`](spec/stress/README.md) explains why). CI runs
the same two steps.

The application code is baked into the image rather than bind-mounted. The `test`, `ingest`,
and `enrich` services therefore declare `pull_policy: build`: even the assignment's bare
`docker compose run --rm test` asks Compose to build the current checkout. Adding `--build`
is harmless and makes that intent explicit, but is not required for those tool services.

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

## How to verify it's working

The four commands the assignment asks for:

```bash
docker compose up --build
docker compose run --rm ingest
docker compose run --rm test
docker compose logs -f
```

**How long before results appear:** the fixture phases below produce rows immediately.
In live mode the worker's first poll attempt can land within about a minute of startup
and repeats on the default 5-minute cadence, but the public feed itself delivers a push
with a documented latency of 30 seconds to 6 hours — see
[Expected time before records appear](#expected-time-before-records-appear).

For a reproducible review, run the phases below **in order** from a fresh clone. Compose fixes
the project name to `github-push-ingestor`, so every clone on a Docker host refers to the same
`github-push-ingestor_pgdata` volume. Do not assume a fresh clone means a fresh database.

### Phase A — cold-image live startup

This phase deliberately uses the default live mode and can spend unauthenticated GitHub
quota. Archive any valued global-volume data first, then remove prior project resources and
prove the volume is absent. Build without cache, remove only the local application image, and
prove that `up --build` can recreate it:

```bash
docker compose down -v --remove-orphans
if docker volume inspect github-push-ingestor_pgdata >/dev/null 2>&1; then
  echo "github-push-ingestor_pgdata still exists" >&2
  exit 1
fi
docker compose build --no-cache --pull
docker image rm github-push-ingestor-app:latest
docker compose up --build -d
docker compose ps --all
until curl -fsS http://localhost:3000/health/ready; do sleep 2; done
```

The only services are `db` (healthy), `setup` (exited 0), `web` (healthy), and `worker`
(running); `ingest`, `enrich`, and `test` do not start. The readiness response is
`{"status":"ok"}`. `/health/live`, `/health/ready`, and `/status` read local state only and
never call GitHub or reserve budget.

A live one-shot may complete, defer until `cadence_due_at`, or report that the source is busy
because the worker owns it. Each is a valid state report:

```bash
docker compose run --rm ingest
docker compose logs --since 5m worker
```

### Phase B — reset, then verify the fixture from an empty volume

The expected fixture totals are absolute, so they are valid only after this destructive phase
boundary. Preserve any valued database first. `down -v` removes the globally named volume and
every stored event; the explicit inspection must fail before the fixture stack starts.

```bash
docker compose down -v --remove-orphans
if docker volume inspect github-push-ingestor_pgdata >/dev/null 2>&1; then
  echo "github-push-ingestor_pgdata still exists" >&2
  exit 1
fi
GITHUB_MODE=fixture docker compose up --build -d db setup web
until curl -fsS http://localhost:3000/health/ready; do sleep 2; done
```

Starting only `db`, `setup`, and `web` keeps the continuous worker from racing the one-shot
fixture commands. Capture the one-shot output directly: `docker compose run --rm` removes its
container, so there is no `ingest` service log to inspect afterward.

```bash
set -o pipefail
fixture_ingest_output="$(mktemp)"
GITHUB_MODE=fixture docker compose run --rm ingest 2>&1 | tee "$fixture_ingest_output"
grep -E 'Push events created:[[:space:]]+4' "$fixture_ingest_output"
grep -E 'Events quarantined:[[:space:]]+3' "$fixture_ingest_output"
grep -E 'Non-push events ignored:[[:space:]]+1' "$fixture_ingest_output"

GITHUB_MODE=fixture docker compose run --rm enrich --limit 6
docker compose exec db psql -U postgres -d github_push_ingestor_development -c "
  SELECT (SELECT COUNT(*) FROM push_events)                     AS push_events,
         (SELECT COUNT(*) FROM github_actors)                   AS actors,
         (SELECT COUNT(*) FROM github_repositories)             AS repositories,
         (SELECT COUNT(*) FROM quarantined_events)              AS quarantined,
         (SELECT SUM(occurrence_count) FROM quarantined_events) AS occurrences;
  SELECT 'actor' AS class, enrichment_status, COUNT(*) FROM github_actors GROUP BY 2
  UNION ALL
  SELECT 'repository', enrichment_status, COUNT(*) FROM github_repositories GROUP BY 2;"
```

The first query must return `4 / 3 / 3 / 3 / 3`. The status query must return
`complete 2 / permanent_failure 1` for each entity class.

To verify replay behavior, wait for the fixture's poll floor and capture the second command's
output too. The removed one-shot container cannot be queried with `docker compose logs`.

```bash
sleep 60
activity_before="$(docker compose exec -T db psql -U postgres \
  -d github_push_ingestor_development -Atc \
  "SELECT md5(string_agg(row_to_json(entities)::text, ',' ORDER BY kind, github_id))
     FROM (SELECT 'actor' AS kind, github_id, first_seen_at, last_seen_at, latest_event_at FROM github_actors
           UNION ALL
           SELECT 'repository', github_id, first_seen_at, last_seen_at, latest_event_at FROM github_repositories) entities;")"
fixture_replay_output="$(mktemp)"
GITHUB_MODE=fixture docker compose run --rm ingest --force 2>&1 | tee "$fixture_replay_output"
grep -E 'Duplicates skipped:[[:space:]]+4' "$fixture_replay_output"
activity_after="$(docker compose exec -T db psql -U postgres \
  -d github_push_ingestor_development -Atc \
  "SELECT md5(string_agg(row_to_json(entities)::text, ',' ORDER BY kind, github_id))
     FROM (SELECT 'actor' AS kind, github_id, first_seen_at, last_seen_at, latest_event_at FROM github_actors
           UNION ALL
           SELECT 'repository', github_id, first_seen_at, last_seen_at, latest_event_at FROM github_repositories) entities;")"
test "$activity_before" = "$activity_after"
rm -f "$fixture_ingest_output" "$fixture_replay_output"
```

Run the isolated suite; `pull_policy: build` means this bare assignment command builds the
current source before it runs:

```bash
docker compose run --rm test
```

### Phase C — recovery and persistence

Reset once more so recovery starts from a deterministic fixture database, then start the
full offline stack. The script keeps every recreation in fixture mode and asserts that the
worker remains there:

```bash
docker compose down -v --remove-orphans
GITHUB_MODE=fixture docker compose up --build -d
GITHUB_MODE=fixture script/verify_recovery.sh --confirm
docker compose exec worker printenv GITHUB_MODE   # fixture
```

`docker kill` is an API-requested stop, so it is the negative control: `unless-stopped` leaves
that container down. The script separately kills each container's main process from the host
PID namespace; that is the crash path on which the policy restarts `db`, `web`, and `worker`.
It also requires `push_events` to remain unchanged after every crash and recovery.

Finally, compare the count around both a normal restart and a Compose down/up cycle. Prefix
every recreation with fixture mode so the worker never spends live quota:

```bash
docker compose exec db psql -U postgres -d github_push_ingestor_development \
  -Atc "SELECT COUNT(*) FROM push_events;"
docker compose restart
docker compose exec db psql -U postgres -d github_push_ingestor_development \
  -Atc "SELECT COUNT(*) FROM push_events;"
docker compose down --remove-orphans
GITHUB_MODE=fixture docker compose up --build -d
docker compose exec db psql -U postgres -d github_push_ingestor_development \
  -Atc "SELECT COUNT(*) FROM push_events;"
```

All three values must be identical. Plain `down` preserves the named volume; only `down -v`
deletes it. See [Crash recovery verification](#crash-recovery-verification) for the
API-stop/process-crash distinction.

A historical transcript of an earlier clean-checkout walk, run from a fresh clone on a
machine with no image, is at
[`docs/evidence/2026-07-31-clean-checkout-verification.md`](docs/evidence/2026-07-31-clean-checkout-verification.md)
— including the live half, which is what shows the public API works with no token.

If something looks wrong, [Troubleshooting and reset](#troubleshooting-and-reset) has a
symptom table and a three-level reset ladder.

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

## Deterministic fixture verification

Fixture mode resolves every request inside [`fixtures/github/`](fixtures/github/)
with no network at all. The numbers below are absolute and require an empty volume; a fresh
checkout is not sufficient because Compose's fixed project name makes the volume global to
the Docker host. Preserve any valued data, then establish the fixture-only baseline:

```bash
docker compose down -v --remove-orphans
if docker volume inspect github-push-ingestor_pgdata >/dev/null 2>&1; then
  echo "github-push-ingestor_pgdata still exists" >&2
  exit 1
fi
GITHUB_MODE=fixture docker compose up --build -d db setup web
```

The worker is intentionally absent so it cannot consume the fixture before the one-shot.
Now the numbers are exact:

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
entity's activity moves. Re-running ingestion cannot duplicate accepted event rows or
register new entity activity from the same event ID; run summaries, quarantine counters,
budget use, and logs may still change. See
[ADR 0005](docs/adr/0005-at-least-once-with-idempotent-writes.md).

### Enrichment, offline

The same corpus resolves every entity the page referenced, so the whole flow — poll,
persist, stub, enrich — runs with no network:

```bash
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

### Fixture scenario matrix

Every scenario resolves inside [`fixtures/github/`](fixtures/github/) with no network at all.
Each poll obeys GitHub's `X-Poll-Interval` floor of 60s, which `--force` deliberately does not
bypass, so allow a minute between successive ingestion scenarios.

| Scenario | Command | What it shows | Cleanup |
|---|---|---|---|
| `default` | `GITHUB_MODE=fixture docker compose run --rm ingest` | 4 push events, 3 actors, 3 repositories, 3 quarantined | none |
| `default` (replay) | `… run --rm ingest --force` after 60s | `duplicates_skipped > 0`, occurrence counts climb, entity activity does not move | none |
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
`script/verify_recovery.sh --confirm --phase=cleanup` runs the SQL under
[Recovering from a fixture rate-limit run](#recovering-from-a-fixture-rate-limit-run), and
`--confirm --phase=rate-limit` plays the rate-limit scenario and cleans up immediately after.

## Inspecting the data

Three endpoints answer "what has it actually done" without a psql session, and none of
them consumes request budget:

```bash
curl -s http://localhost:3000/status | jq
curl -s 'http://localhost:3000/api/push_events?limit=5' | jq
curl -s http://localhost:3000/api/push_events/<github_event_id> | jq .data.raw_payload
```

### `GET /status`

Reports persisted state only: the poll schedule per event source (all five of §9's
components, plus which one is binding), the per-class ledger state, §11's three
enrichment coverage percentages, the per-status entity counts, and durable-backlog
telemetry: per-class size, oldest pending timestamp/age, and reserved allowance usage.

Three conventions in the response body are worth knowing before reading one:

- **`null` is never a zero.** A counted zero prints `0`; a number that does not
  exist prints `null`. Where `null` would be ambiguous the disambiguating fact gets
  its own field — `ledger.present` separates "no ledger row yet" from "remaining is
  genuinely 0", `due_now` separates "no constraint applies" from "unknown", and
  `claimable_now` says whether work is eligible under persisted backlog and ledger state;
  `backlog_count`, `next_enrichment_at`, and the ledger window/block fields distinguish
  deferred work from an empty backlog. An empty coverage window reports `null`
  percentages, not `0.0`: the ratio is undefined, not zero, and every denominator is
  published beside its ratio so you can check it.
- **The coverage window is measured on `created_at`** — when *this application*
  persisted the event, not GitHub's `occurred_at`. Coverage grades this
  application's enrichment pipeline and uses the same local clock as backlog and
  freshness reporting. The basis is published as
  `coverage.basis` so the choice is visible rather than assumed. Widen
  `ENRICHMENT_COVERAGE_WINDOW_SECONDS` when reviewing a fixture corpus that has aged.
- **`actor_requests.available` is a floor, not a ceiling.** §10 lets one class
  borrow the other's unspent capacity when the other has no claimable backlog candidate, so a
  class does not stop at zero available. The real ceiling is the `enrichment` pair
  beside it.

`pending` in the entity counts means `enrichment_status = 'pending'` exactly. The
`backlog_count` beside it is pending **plus** `retryable_failure` — the "how much work is
left" number the command summary prints. That work has no age cutoff. `/status`
deliberately does not publish a drain ETA: the schema has no durable outcome history from
which to calculate an honest service rate, and sustained arrivals can make the backlog grow
indefinitely.

### `GET /api/push_events` and `GET /api/push_events/:id`

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

### Database inspection

The queue is a database too, so one tool inspects everything. Each query below assumes
this prefix:

```bash
docker compose exec db psql -U postgres -d github_push_ingestor_development -c "…"
```

**How much was captured**

```sql
SELECT (SELECT COUNT(*) FROM push_events)                     AS push_events,
       (SELECT COUNT(*) FROM github_actors)                   AS actors,
       (SELECT COUNT(*) FROM github_repositories)             AS repositories,
       (SELECT COUNT(*) FROM quarantined_events)              AS quarantined,
       (SELECT SUM(occurrence_count) FROM quarantined_events) AS occurrences,
       (SELECT COUNT(*) FROM ingestion_runs)                  AS runs;
```

**Where enrichment stands, per class**

```sql
SELECT 'actor' AS class, enrichment_status, COUNT(*) FROM github_actors GROUP BY 2
UNION ALL
SELECT 'repository', enrichment_status, COUNT(*) FROM github_repositories GROUP BY 2
ORDER BY 1, 2;
```

**The budget ledger, whole**

```sql
SELECT window_status, "limit", remaining, reserve,
       poll_used, poll_allowance, enrichment_used, enrichment_allowance,
       actor_share_used, repository_share_used,
       global_blocked_until, reset_at, consecutive_secondary_limits
  FROM github_api_budget;
```

**The last five runs and what they did**

```sql
SELECT run_id, status, started_at, pages_fetched, events_created,
       duplicates_skipped, events_quarantined, events_failed
  FROM ingestion_runs ORDER BY started_at DESC LIMIT 5;
```

**What was quarantined, and how often it recurred**

```sql
SELECT github_event_id, event_type, error_code, occurrence_count,
       first_received_at, last_received_at
  FROM quarantined_events ORDER BY occurrence_count DESC;
```

**Why a source is or is not due** — all five scheduling components side by side

```sql
SELECT source_type, status, enabled, consecutive_failures,
       cadence_due_at, poll_floor_until, retry_not_before_at, next_poll_at
  FROM event_sources;
```

**The queue** — a different database, same tool

```bash
docker compose exec db psql -U postgres -d github_push_ingestor_queue_development \
  -c "SELECT key, class_name, schedule FROM solid_queue_recurring_tasks;" \
  -c "SELECT class_name, count(*) FROM solid_queue_jobs GROUP BY 1;" \
  -c "SELECT kind, name, last_heartbeat_at FROM solid_queue_processes;"
```

## The data model

Seven business tables in three groups:

- **Source and run state** — `event_sources` (what to poll and when), `ingestion_runs`
  (what each attempt did).
- **Business records** — `push_events`, `github_actors`, `github_repositories`,
  `quarantined_events`.
- **The global ledger** — `github_api_budget`, one row.

A second database, `github_push_ingestor_queue_development`, holds Solid Queue's tables.
Queued enrichment dispatches are hints, not the pending-enrichment source of truth: removing
those hints does not erase eligible entity state committed in the business database, and a
later successful reconciler tick can rediscover that work. Other operational queue state is
not claimed to be reconstructible. See
[ADR 0008](docs/adr/0008-post-commit-enqueue-and-entity-scoped-reconciliation.md).

| Table | What a row is | Identity | Written by |
|---|---|---|---|
| `event_sources` | one pollable feed and its schedule | `source_type` | `Ingestion::PollState`, `SourceProvisioner` |
| `ingestion_runs` | one poll attempt that reached GitHub | `run_id` (uuid, unique) | `Ingestion::RunRecorder` |
| `push_events` | one accepted GitHub `PushEvent` | `github_event_id` (unique) | `Ingestion::PageWriter` |
| `github_actors` | one GitHub user seen pushing | `github_id` (unique) | `PageWriter` (stub), `Enrichment::EntityState` |
| `github_repositories` | one GitHub repository seen receiving a push | `github_id` (unique) | `PageWriter` (stub), `Enrichment::EntityState` |
| `quarantined_events` | one distinct malformed payload | `payload_fingerprint` (unique) | `Ingestion::PageWriter` |
| `github_api_budget` | the hourly request budget | `id = 1` (check constraint) | `Github::BudgetLedger` |

### Columns that carry a rule

**`push_events`** — the durability boundary.

| Column | Type | The rule it encodes |
|---|---|---|
| `github_event_id` | `text` **unique** | GitHub's own event id. The unique index *is* the deduplication mechanism |
| `github_push_id` | `bigint` | `payload.push_id`; indexed but not unique — GitHub does not guarantee it is |
| `github_actor_id` | `bigint` FK → `github_actors.github_id` | The FK targets GitHub's identifier, **not** the surrogate primary key |
| `github_repository_id` | `bigint` FK → `github_repositories.github_id` | Same |
| `ref` | `text` `NOT NULL` | `payload.ref` |
| `head_sha`, `before_sha` | `varchar(64)` `NOT NULL` | `payload.head` and `payload.before`. 64, not 40, so **both SHA-1 and SHA-256 object names are accepted** |
| `occurred_at` | `timestamp` `NOT NULL`, indexed | GitHub's `created_at`. Distinct from this row's `created_at`, which is when *this* application persisted it |
| `raw_payload` | `jsonb` `NOT NULL` | Retention is **semantic, not byte-exact** ([ADR 0001](docs/adr/0001-jsonb-semantic-retention.md)) |

**`github_actors` / `github_repositories`** — identical enrichment state machines.

| Column | Type | The rule it encodes |
|---|---|---|
| `github_id` | `bigint` **unique** | Identity. The stub upsert conflicts on this |
| `enrichment_status` | `text`, check-constrained | Four legal values; see below |
| `first_seen_at`, `last_seen_at`, `latest_event_at` | `timestamp` | Activity. Updated **only** when a `push_events` insert actually returned a row |
| `next_retry_at` | `timestamp` | Double duty: the backoff instant *and* the enrichment lease. One column, one predicate, so candidate selection and claiming cannot drift apart |
| `fetched_at` | `timestamp` | When enrichment last succeeded — the input to the refresh TTL |
| `raw_payload` | `jsonb` nullable | The enrichment response. Null until a fetch succeeds |

**`event_sources`** — five independent scheduling columns, never one collapsed timestamp:
`cadence_due_at`, `poll_floor_until`, `retry_not_before_at`, plus the ledger's
`global_blocked_until` and a derived class block. `next_poll_at` is a **cache of the
answer, never an input** ([ADR 0006](docs/adr/0006-decomposed-poll-deferral-state.md)).
`status` is `idle` or `failed` by check constraint; `enabled` is the separate operator
switch.

**`quarantined_events`** — `payload_fingerprint` is the sole identity: SHA-256 of compact
UTF-8 JSON with recursively sorted object keys. `github_event_id` is nullable and indexed
but **not unique**, because a malformed event may be malformed precisely because it has no
event id. `occurrence_count` is check-constrained `>= 1` and climbs on replay.

**`github_api_budget`** — a `CHECK (id = 1)` singleton, because the unauthenticated quota
is keyed to the outbound IP rather than to a source. `window_status` is
`uninitialized` / `active` / `globally_blocked`; every counter is check-constrained
non-negative; `consecutive_secondary_limits` survives window rollover because secondary
limits are IP-scoped rather than window-scoped
([ADR 0010](docs/adr/0010-secondary-limit-escalation-and-refresh-pool-fairness.md)).

### The enrichment state machine

| Status | Entered when | Left when | Spends budget |
|---|---|---|---|
| `pending` | Ingestion creates a stub row | Success, a retryable outcome, or a permanent outcome | When a request is admitted; not for a URL-policy rejection |
| `complete` | An enrichment fetch succeeds | Stays complete while fresh; after TTL it may refresh once the backlog is observed empty. Transient refresh failures keep it complete; terminal outcomes may make it `permanent_failure` | When a refresh request is admitted |
| `retryable_failure` | A retryable entity or transport outcome occurs | Retried after backoff; leaves on success or a permanent outcome | When a request is admitted |
| `permanent_failure` | A permanent response, document, redirect/policy, or transport outcome occurs | Never, automatically | Every admitted outbound attempt; a pre-gate URL rejection spends none |

`pending` and `retryable_failure` rows are the durable backlog. Within each entity class
they are selected FIFO, oldest first, and quota exhaustion only defers them to a later
window. A duplicate replay may refresh identity fields but does not register new activity
or change backlog priority.

### Replay behavior by table

| Table | Write | Effect on replay |
|---|---|---|
| `push_events` | `INSERT … ON CONFLICT (github_event_id) DO NOTHING RETURNING id` | No-op; the accepted raw event is never mutated |
| `github_actors`, `github_repositories` | `INSERT … ON CONFLICT (github_id) DO UPDATE` on identity fields only | Identity refreshed; enrichment payload untouched |
| `quarantined_events` | `INSERT … ON CONFLICT (payload_fingerprint) DO UPDATE` | `occurrence_count` increments; the first classification is permanent |
| Entity activity fields | Gated on the `push_events` insert returning a row | No activity registered |

Transactions are **one per event**, not one per page, so a single malformed envelope can
never discard the events persisted beside it. Quarantine writes stand outside any
transaction.

### Indexes worth knowing

Three are partial — the predicate lives in the index rather than only in the query, so the
planner scans only rows that could possibly qualify:

- `index_event_sources_on_poll_due` on `(source_type, next_poll_at)`
  `WHERE enabled AND status = 'idle'` — the tick's due-source scan.
- `index_github_{actors,repositories}_on_enrichment_candidates` on the oldest-first keys
  `(created_at, id)`,
  `WHERE enrichment_status IN ('pending','retryable_failure')` — the durable FIFO
  candidate pool. `created_at` is immutable and non-null; `first_seen_at` can be null.
- `index_github_{actors,repositories}_on_enrichment_refresh` on `(fetched_at, next_retry_at)`
  `WHERE enrichment_status = 'complete'` — the TTL refresh pool.

[`db/schema.rb`](db/schema.rb) is authoritative (version `2026_08_02_000000`). For live
truth:

```bash
docker compose exec db psql -U postgres -d github_push_ingestor_development -c "\d+ push_events"
```

The compact architecture figure in
[`docs/DESIGN_BRIEF.md`](docs/DESIGN_BRIEF.md) shows how the runtime and PostgreSQL state
fit together.

## Logs

### Anatomy of a log line

One JSON object per line on stdout. Four fields are owned by
[`lib/json_log_formatter.rb`](lib/json_log_formatter.rb) and cannot be overridden by an
application payload — a structured event can never spoof its own severity, service,
environment or timestamp:

```json
{
  "timestamp": "2026-07-31T15:50:49.973Z",
  "level": "info",
  "service": "github-push-ingestor",
  "environment": "development",
  "event": "ingestion.run_completed",
  "run_id": "099d562d-1261-488d-9003-cb0c443cdb55",
  "event_source_id": 1,
  "duration_ms": 100.7,
  "run_status": "completed",
  "pages_fetched": 1,
  "events_received": 8,
  "push_events_seen": 6,
  "events_created": 4,
  "duplicates_skipped": 0,
  "events_quarantined": 3,
  "events_ignored": 1,
  "events_failed": 0
}
```

### Sample stream

Representative, intentionally abridged excerpts from a fixture-mode run against an empty
database, with queue and backlog fields updated to the current routing. Fields omitted from
the excerpts remain present in the actual structured logs. You can reproduce them offline:

```bash
GITHUB_MODE=fixture docker compose up --build -d
GITHUB_MODE=fixture docker compose run --rm ingest 2>&1 | grep '^{'
docker compose logs --no-log-prefix worker | grep '^{'
GITHUB_MODE=fixture GITHUB_FIXTURE_SCENARIO=transient_failure \
  docker compose run --rm ingest --force 2>&1 | grep '^{'
```

The `grep '^{'` is load-bearing: `bin/ingest` shares stdout between the operator summary
and the JSON stream, so a leading brace is exactly what separates them.

Boot, then a poll that created four events and quarantined three:

```text
{"timestamp":"2026-07-31T15:50:49.677Z","level":"info","service":"github-push-ingestor","environment":"development","event":"config.budget_resolved","mode":"fixture","poll_interval_seconds":300,"max_pages_per_poll":1,"enabled_live_source_count":1,"worst_case_reservations_per_poll":9,"limit":60,"reserve":8,"poll_allowance":12,"enrichment_allowance":40,"actor_guarantee":20,"repository_guarantee":20}
{"timestamp":"2026-07-31T15:50:49.896Z","level":"info","service":"github-push-ingestor","environment":"development","event":"ingestion.run_started","run_id":"099d562d-1261-488d-9003-cb0c443cdb55","event_source_id":1,"source_type":"github_fixture_events","github_mode":"fixture","forced":false,"lock_wait_ms":2.2}
{"timestamp":"2026-07-31T15:50:49.924Z","level":"info","service":"github-push-ingestor","environment":"development","event":"budget.window_initialized","limit":60,"reserve":8,"poll_allowance":12,"enrichment_allowance":40,"actor_guarantee":20,"repository_guarantee":20,"rate_limit_resource":"core","rate_limit_limit":60,"rate_limit_remaining":59,"rate_limit_used":1,"rate_limit_reset_at":"2026-07-31T16:50:49Z","poll_used":1}
{"timestamp":"2026-07-31T15:50:49.965Z","level":"info","service":"github-push-ingestor","environment":"development","event":"ingestion.event_quarantined","run_id":"099d562d-1261-488d-9003-cb0c443cdb55","github_event_id":"58000000006","event_type":"PushEvent","error_code":"invalid_field_format","error_message":"payload.head is \"not-a-valid-object-name\", not 40 or 64 hexadecimal characters","payload_fingerprint":"a8ad67ca97a4c48049f5fa447d5d88ae10c58c514e0129546e18b5ff22368020"}
{"timestamp":"2026-07-31T15:50:49.973Z","level":"info","service":"github-push-ingestor","environment":"development","event":"ingestion.run_completed","run_id":"099d562d-1261-488d-9003-cb0c443cdb55","event_source_id":1,"duration_ms":100.7,"next_poll_at":"2026-07-31T15:55:49Z","consecutive_failures":0,"run_status":"completed","classification":"ok","stop_reason":"no_next_link","pages_fetched":1,"events_received":8,"push_events_seen":6,"events_created":4,"duplicates_skipped":0,"events_quarantined":3,"events_ignored":1,"events_failed":0}
{"timestamp":"2026-07-31T15:50:50.024Z","level":"info","service":"github-push-ingestor","environment":"development","event":"enrichment.dispatched","actor_enqueued":1,"repository_enqueued":1,"reason":"ingestion","actor_counts":{"pending":3},"repository_counts":{"pending":3},"actor_backlog_count":3,"repository_backlog_count":3,"actor_oldest_pending_age_seconds":0,"repository_oldest_pending_age_seconds":0,"actor_share_used":0,"repository_share_used":0,"actor_guarantee":20,"repository_guarantee":20,"enrichment_used":0,"enrichment_allowance":40,"window_status":"active","claimable_now":true}
```

A second run inside the cadence window makes no request at all, and names the component
holding it:

```text
{"timestamp":"2026-07-31T15:51:00.142Z","level":"info","service":"github-push-ingestor","environment":"development","event":"ingestion.not_due","event_source_id":1,"forced":false,"deferral_reason":"cadence_due_at","next_poll_at":"2026-07-31T15:55:49Z","cadence_due_at":"2026-07-31T15:55:49Z","poll_floor_until":"2026-07-31T15:51:49Z"}
```

From the worker — a job, its enrichment outcome, and the deliberate `404` the corpus plants
so a dead target fails the *entity* rather than the source:

```text
{"timestamp":"2026-07-31T15:50:50.780Z","level":"info","service":"github-push-ingestor","environment":"development","event":"job.completed","job_id":"58a1e78d-f473-4440-aee0-fe0bbb22027f","job_class":"EnrichActorJob","queue":"enrichment","attempt":1,"duration_ms":74.6,"entity_type":"actor","github_actor_id":7700421,"enrichment_outcome":"failed"}
{"timestamp":"2026-07-31T15:50:50.780Z","level":"info","service":"github-push-ingestor","environment":"development","enrichment_outcome":"failed","entity_type":"actor","github_id":7700421,"pool":"pending","classification":"not_found","entity_status":"permanent_failure","enrichment_attempt":1,"error_message":"GitHub returned 404 (not_found)","duration_ms":56.6,"event":"enrichment.failed"}
{"timestamp":"2026-07-31T15:51:00.949Z","level":"info","service":"github-push-ingestor","environment":"development","enrichment_outcome":"enriched","entity_type":"actor","github_id":1024025,"pool":"pending","classification":"ok","entity_status":"complete","enrichment_attempt":1,"duration_ms":27.3,"event":"enrichment.completed"}
```

A retry ladder, from the `transient_failure` scenario — the failed request at `warn`, the
scheduled backoff at `info` reporting the delay actually slept:

```text
{"timestamp":"2026-07-31T15:52:11.046Z","level":"warn","service":"github-push-ingestor","environment":"development","event":"github.request","request_class":"poll","http_method":"get","url":"fixture://api.github.com/events?per_page=100","origin":"application","run_id":"2de73c38-2d98-4f90-b09b-53044ac54395","source_type":"github_fixture_events","http_status":500,"classification":"server_error","attempt":0,"duration_ms":0.0}
{"timestamp":"2026-07-31T15:52:11.046Z","level":"info","service":"github-push-ingestor","environment":"development","event":"github.retry_scheduled","request_class":"poll","http_method":"get","url":"fixture://api.github.com/events?per_page=100","origin":"application","run_id":"2de73c38-2d98-4f90-b09b-53044ac54395","source_type":"github_fixture_events","http_status":500,"classification":"server_error","attempt":0,"duration_ms":0.0,"next_attempt":1,"max_attempts":2,"backoff_seconds":1.2}
```

That run also demonstrates the replay contract in one line — the same page, zero created,
four absorbed:

```text
{"timestamp":"2026-07-31T15:52:14.560Z","level":"info","service":"github-push-ingestor","environment":"development","event":"ingestion.run_completed","run_id":"2de73c38-2d98-4f90-b09b-53044ac54395","event_source_id":1,"duration_ms":3539.3,"next_poll_at":"2026-07-31T15:57:14Z","consecutive_failures":0,"run_status":"completed","classification":"ok","stop_reason":"no_next_link","pages_fetched":1,"events_received":8,"push_events_seen":6,"events_created":0,"duplicates_skipped":4,"events_quarantined":3,"events_ignored":1,"events_failed":0}
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
and the attempt number; budget/class-exhaustion and reconciliation summaries show when
durable backlog work is waiting for a later quota window; `enrichment.lease_lost` appears
at warning level when an outcome arrived after another worker had claimed the row; and
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

Background work adds the job vocabulary: `job.completed` for every job the worker
runs — carrying `job_id`, `job_class`, `queue`, `attempt`, `duration_ms` and the
identifiers that job produced — and `job.failed` with the error class and message
when one raises. `ingestion.source_busy` reports a tick that found the source owned
by another poller, `ingestion.cycle_failed` one source that failed without stopping
the tick, and `enrichment.dispatched` is the reconciliation summary: what it
scheduled, what blocked it, and the per-class state counts and share usage. A tick
that scheduled nothing keeps that line at debug, so an exhausted window does not
emit a line a minute for the rest of the hour.

`LOG_LEVEL=debug` adds the `github.request` line for requests that **succeeded** (the
failing ones are already at warning), `ingestion.page_fetched` and
`ingestion.page_processed` per page, `ingestion.pagination_stopped` with its reason,
`ingestion.not_modified` — which carries the `x-ratelimit-used` and
`x-ratelimit-remaining` that make the `304` accounting visible in the running
system — `budget.co_tenant_usage`, plus a line per persisted, duplicate and ignored
event.

### Reading the stream

Every line carries the run's `run_id`, except `ingestion.not_due`: a poll the
schedule turned away opens no run, so it reports `event_source_id` instead. **The trace is
one hop** — a `job_id` on `job.completed` gives the `run_id`s that job opened, and every
`ingestion.*` line carries the `run_id`.

```bash
# one run, end to end
docker compose logs | grep '"run_id":"099d562d-1261-488d-9003-cb0c443cdb55"'

# one job, and the runs it opened
docker compose logs worker | grep -E 'job\.(completed|failed)|enrichment\.dispatched'

# everything that went wrong
docker compose logs | grep -E '"level":"(warn|error)"'

# every budget state transition
docker compose logs | grep '"event":"budget\.'
```

## Rate limits and the request budget

### The allowance formula

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

The enrichment allowance is then split by `ACTOR_ENRICHMENT_SHARE` (plan §10):

```text
actor_guarantee      = floor(enrichment_allowance x ACTOR_ENRICHMENT_SHARE)
repository_guarantee = enrichment_allowance - actor_guarantee
```

With the defaults: 20 actor and 20 repository attempts an hour. The remainder
always goes to repositories, because the formula floors one side and subtracts for
the other — so the two always add up to the whole allowance.

### The budget table

At limit 60, reserve 8, cadence 300s, one source — the only variable is page depth:

| `MAX_PAGES_PER_POLL` | Poll allowance | Enrichment allowance | Actor guarantee | Repository guarantee |
|---|---|---|---|---|
| 1 (default) | 12 | 40 | 20 | 20 |
| 2 | 24 | 28 | 14 | 14 |
| 3 | 36 | 16 | 8 | 8 |
| 4 | 48 | 4 | 2 | 2 |
| 5 | 60 | — | — | **refuses to boot** |

Capture depth is bought with backlog-drain capacity, at a fixed exchange rate, and the
formula tells you the price before you pay it.

### Global blocks versus class exhaustion

Two different things that both stop requests, deliberately kept apart:

- **A global block** is the only thing written to `github_api_budget.global_blocked_until`,
  and it only ever moves later. Primary exhaustion, a reserve breach, and a secondary rate
  limit set it; it stops **everything**. `budget.global_block_set` and
  `budget.global_block_cleared` mark the edges.
- **Class exhaustion** is *derived* from the counters and writes nothing. When polling has
  spent its twelve, enrichment carries on; when enrichment has spent its forty, polling
  carries on. `budget.class_exhausted` fires once per class per window, and
  `budget.share_exhausted` once per fairness share.

So "the poller ran out" never means "the system stopped", and a reviewer can tell which
happened from one log line.

### Per-window bootstrap

The ledger is never seeded by a discovery request. The **first canonical page-one poll of
each rate-limit window** initialises it from that response's authoritative headers — it is
a normal, counted, event-processing poll that happens to also establish the window. Until
the window is `active`, enrichment is ineligible. `budget.window_initialized` marks it,
`budget.window_rolled` marks the hour turning over, and `budget.window_reset_in_past` warns
that this container's clock runs ahead of GitHub's
([ADR 0004](docs/adr/0004-class-aware-budget-ledger.md)).

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

## Configuration

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
| `MAX_PAGES_PER_POLL` | `1` | How many `Link`-followed pages one poll may fetch, and an allowance-formula input. Raising it trades enrichment allowance for capture depth — see [the budget table](#the-budget-table) (plan §9, §10) |
| `ENABLED_LIVE_SOURCE_COUNT` | `1` | Allowance-formula input: live sources sharing one per-IP budget. **A fallback rather than the authority** — at window initialization and rollover the formula counts the enabled, in-service `event_sources` rows of the running mode and uses that instead, falling back to this value only when there are none yet. A disagreement is logged as `budget.source_allocation_drift` (plan §10, [ADR 0009](docs/adr/0009-runtime-source-allocation-and-shared-ip-observability.md)) |
| `RATE_LIMIT_RESERVE` | `8` | Requests per hour left deliberately unspent (plan §10) |
| `ACTOR_ENRICHMENT_SHARE` | `0.50` | How the enrichment allowance splits between actors and repositories: `floor(allowance x this)` guarantees actors, the remainder goes to repositories. A guarantee, not a cap — either class may borrow the other's unused capacity when the other has no *currently claimable* backlog candidate. Both ends of `[0, 1]` are legal (plan §10) |
| `ACTOR_REFRESH_TTL_SECONDS` | `86400` | Minimum reuse time before an enriched actor may be re-fetched. At each selection decision, refreshes are suppressed when either class has never-enriched backlog work (plan §10); see limitation 7 for the bounded concurrent-insert window |
| `REPOSITORY_REFRESH_TTL_SECONDS` | `86400` | The same, for repositories |
| `ENRICHMENT_COVERAGE_WINDOW_SECONDS` | `86400` | How far back `GET /status` looks when computing §11's three coverage percentages, measured on `push_events.created_at`. The only knob here that changes what the system *reports* rather than what it *does* |

Database connection settings (`POSTGRES_HOST`, `POSTGRES_PORT`,
`POSTGRES_USER`, `POSTGRES_PASSWORD`) are managed by the compose topology
itself and matter only when running the app outside compose.

There is deliberately no variable for the API host or the API version — see
[The SSRF boundary](#the-ssrf-boundary) and
[ADR 0011](docs/adr/0011-pinned-api-version-2022-11-28.md).

## Architecture

[`docs/DESIGN_BRIEF.md`](docs/DESIGN_BRIEF.md) is the two-page architecture summary, with
one compact architecture figure. This section is the annotated call chain.

Every live GitHub request — polling and enrichment, from the poller, the worker, or the
one-shot — takes one chain, and nothing outside it calls GitHub
(`IMPLEMENTATION_PLAN.md` §5, §10):

```text
IngestionRunner ──► SourceLock ──► PollSchedule (due? — five components, §9)
                                 │
                                 ├──► PageLoop ──► RequestExecutor ──► RequestGate
EnrichmentRunner ────────────────┘      │ ▲                        ──► BudgetLedger.reserve!
  FIFO backlog → class, borrow          │ │                        ──► UrlPolicy
  Refresh after backlog observed empty  │ └── LinkHeader.next_url  ──► Transport (Faraday | Fixture)
  Claim → lease on next_retry_at        │                                   │
  (never a SourceLock, §8 step 1)       │                                   ▼
                                        │                  PageWriter: one transaction per event
                                        │                  stub upserts → INSERT … ON CONFLICT
                                        │                  DO NOTHING RETURNING id → entity
                                        │                  activity updates only when
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
- **`Github::UrlPolicy`** is the SSRF boundary — see below.
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
  entity: it asks fairness which class works next, claims the oldest row in that class,
  fetches through the same chain, and writes one outcome. A denied reservation leaves the
  row durable for a later window. It never takes a source lock and opens no transaction
  across the request.
- **`Github::Enrichment::Fairness`** applies §10's ladder: a never-enriched candidate in a
  class still inside its guarantee, then borrowing when the other class has no
  *currently claimable* backlog candidate, then a TTL-stale refresh only when the selection
  observes no never-enriched work in either class. Once refresh is allowed, it uses the same
  two steps — prefer a class with room, then borrow only from a class with nothing to
  refresh — so one refresh class cannot starve the other. Fairness decides; the ledger
  enforces, so a wrong answer produces a refused reservation rather than an overspend
  ([ADR 0007](docs/adr/0007-enrichment-fairness-shares-and-borrowing.md),
  [ADR 0010](docs/adr/0010-secondary-limit-escalation-and-refresh-pool-fairness.md)).
- **`Github::Enrichment::Claim`** prevents two workers enriching one entity by leasing the
  row — a conditional `UPDATE` that pushes `next_retry_at` forward. One column, one
  meaning: the same predicate excludes leases, backoffs and secondary-limit deferrals from
  candidate selection, so the queries cannot drift apart. A crashed worker leaves nothing
  to clean up; the lease expires.
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

### The SSRF boundary

Enrichment follows URLs that arrive **inside GitHub payloads**, `Link` headers and
`Location` headers — data this application did not construct and an attacker could
influence. So `Github::UrlPolicy` is a trust boundary, not a formatter. Every URL is
rebuilt from validated components, and a `:payload`-origin URL always clears the full
*live* policy first, whatever mode the process is in:

- HTTPS only
- Host exactly `api.github.com`
- No userinfo (`https://evil@api.github.com/…` is refused)
- No non-default port
- No IP literals
- Redirects bounded by `MAX_REDIRECTS`, each hop re-validated and separately debited

The allowed host is a **constant, not an environment variable** — a deployment setting
there would make the trust boundary configurable. The API version is pinned to
`2022-11-28` for the same class of reason
([ADR 0011](docs/adr/0011-pinned-api-version-2022-11-28.md)). Fixture mode fails closed:
an unknown URL is an error, never a live fallback
([ADR 0003](docs/adr/0003-event-source-and-transport-seams.md)).

It is demonstrable offline. The `hostile_redirect` scenario serves a `301` whose `Location`
points off-host:

```bash
GITHUB_MODE=fixture GITHUB_FIXTURE_SCENARIO=hostile_redirect \
  docker compose run --rm enrich --class repository
docker compose logs | grep '"event":"github.request"' | grep '"level":"warn"'
```

The second hop is never sent, the entity records the failure, and **the event source stays
in service** — a refused redirect is a fact about one entity, not about the feed. Compare
`redirecting_repository`, where a legitimate rename is followed across one validated hop
and debited twice.

Decisions behind this are recorded in
[`docs/adr/`](docs/adr/): `jsonb` semantic retention (0001), advisory locks and the gate
(0002), the source and transport seams (0003), the class-aware ledger (0004),
repeated execution with duplicate-safe event writes (0005), decomposed poll deferral state
(0006), enrichment fairness shares and borrowing (0007), post-commit enqueue with
entity-scoped reconciliation (0008), runtime source allocation with shared-IP
observability (0009), secondary-limit escalation with refresh-pool fairness (0010), the
pinned API version (0011), and Solid Queue over Kafka (0012).

## Continuous ingestion

The `worker` container runs one Solid Queue supervisor: a dispatcher, a scheduler running
[`config/recurring.yml`](config/recurring.yml), and two single-thread worker processes from
[`config/queue.yml`](config/queue.yml). One process serves `polling,control`; the other is
dedicated to `enrichment`, so polling and control work never queue behind the enrichment
workload. Outbound polling and enrichment attempts still serialize through `RequestGate`.
Two tasks fire every 60 seconds.

**A tick is not a poll.** `PollEventSourceJob` selects the sources whose cached
`next_poll_at` has arrived, and `Github::IngestionRunner` then re-reads each one
inside its advisory lock and applies §9's five components before spending anything.
At the default 300-second cadence roughly four ticks in five cost one indexed
`SELECT` and nothing else. The tick exists so a source that becomes due at T is
eligible on the next successful scheduled tick — not so that polls happen every minute,
which the allowance formula (twelve poll requests an hour, no headroom) could not pay for.
A source another process is polling is reported at INFO and left alone; the tick
does not retry it in the same execution; another tick is nominally scheduled 60 seconds later.

**Enrichment is scheduled twice over, deliberately.** A run that created events
schedules one cycle per class as soon as its rows are committed and its advisory
lock is released. That enqueue is a *hint*: the durable record of pending work is the
entity rows themselves, so `ReconcilePendingEnrichmentsJob` sweeps them every 60
seconds and schedules a cycle for any class that has claimable work and is not
blocked by the ledger. If a crash loses an enrichment-dispatch hint, the committed
entity state remains discoverable on a later successful scheduled tick without a special
cleanup job or queue inspection (plan §8,
[ADR 0008](docs/adr/0008-post-commit-enqueue-and-entity-scoped-reconciliation.md)).

Each dispatch call enqueues at most one job per class regardless of backlog depth; entity
rows, not queued jobs, are the backlog. Each cycle enriches at most one entity, chosen by
§10's fairness policy under a lease.
Steady state at the defaults: twelve polls an hour, and at most forty enrichment
requests an hour split into 20/20 actor/repository guarantees with borrowing. Within each
class the oldest never-enriched entity is selected first; a selection considers refresh
work only after observing the entire never-enriched backlog empty.

## Processing guarantees

**An event is accepted when its `push_events` row commits** — not when GitHub returns it,
not when a job is enqueued, not when a log line says so. That row is durable. Work lost
before its commit is recoverable only while the event remains in a later GitHub feed window;
pending enrichment can be reconstructed from committed entity state.

The demonstrated invariant is deliberately specific: a duplicate observation of a valid
event cannot create another `push_events` row or register new entity activity. That does
not make the surrounding execution singular. A retry may create
another ingestion-run row, increment a malformed payload's occurrence counter, spend another
budget reservation, execute another job, or emit another log line, depending on its crash
boundary.

### What is not claimed, and why

- **Not exactly-once execution.** A job may run twice. The unique event row and guarded entity
  activity update are replay-safe; execution records, counters, budget use, and logs may repeat.
- **Not complete upstream capture.** The feed is a sliding window with hours of latency;
  see [Known limitations](#known-limitations).
- **Not bounded-time enrichment completion.** Durable work is not discarded, but sustained
  arrivals can exceed the 40-request hourly service rate; see [Known
  limitations](#known-limitations).

### The four crash cases

| Crash point | What survives | What recovers it |
|---|---|---|
| Before the event commits | Nothing from this page | A later overlapping poll can re-fetch it only while it remains in GitHub's feed window; there is no stop-on-known-event |
| After the event commits, before enrichment is enqueued | The `push_events` row and its stub entities | `ReconcilePendingEnrichmentsJob`, from committed entity rows, on a later successful tick (scheduled every 60s) |
| Worker dies before the enrichment commit | The entity row, still `pending`, its lease expiring by arithmetic | The next reconcile tick after `next_retry_at` passes |
| Worker dies after the enrichment commit, before acknowledgement | The enriched entity row | Solid Queue may re-run the job; the freshness check leaves that row unchanged |

### The mechanisms

- `INSERT … ON CONFLICT (github_event_id) DO NOTHING RETURNING id` — the deduplication gate.
- Activity updates gated on that `RETURNING` — so a replay may refresh identity but cannot
  register new activity or change FIFO backlog age.
- `payload_fingerprint` uniqueness on quarantine — one row per distinct malformed payload,
  occurrence-counted.
- The entity lease is a `next_retry_at` timestamp that **expires by arithmetic**, so a
  crashed worker leaves nothing to release.
- Session advisory locks die with their PostgreSQL session, so a killed poller releases its
  source the moment its connection drops.
- `enqueue_after_transaction_commit` plus an entity-scoped reconciler — the enqueue is a
  hint, the committed rows are the record.
- `restart: unless-stopped` on `db`, `web`, and `worker`.

[ADR 0005](docs/adr/0005-at-least-once-with-idempotent-writes.md) argues the choice;
[ADR 0008](docs/adr/0008-post-commit-enqueue-and-entity-scoped-reconciliation.md) covers
recovery; [Crash recovery verification](#crash-recovery-verification) exercises it.

## Crash recovery verification

`IMPLEMENTATION_PLAN.md` §15 step 8 asks a reviewer to exercise both operator-requested stops
and main-process crashes. Run it with one command against a stack started in fixture mode:

```bash
GITHUB_MODE=fixture docker compose up --build -d
GITHUB_MODE=fixture script/verify_recovery.sh --confirm
```

A historical transcript from an earlier script revision is committed at
[`docs/evidence/2026-07-31-container-kill-recovery.md`](docs/evidence/2026-07-31-container-kill-recovery.md).
Its prominent erratum explains why its green verdict is not the current submission gate; the
corrected script must be rerun against the final default-branch SHA.
Nothing in CI runs the script — it kills containers and writes to the development databases,
and `spec/docker_compose_spec.rb` asserts that no workflow references it.

**Read §15's command knowing what it does.** `docker kill` is an API stop: the daemon records
the container as manually stopped, and `restart: unless-stopped` is defined to skip exactly
that case. So the documented command leaves the container down, and

```bash
docker kill github-push-ingestor-worker-1
docker compose ps          # Exited (137) — and it stays that way
GITHUB_MODE=fixture docker compose up -d worker
```

is the honest sequence. The restart policy is sound; it is the *kill* that does not exercise
it. A crash — the container's main process dying rather than being stopped through the API —
does, and every service recovered on its own with no operator step. The script performs both
and reports both.

One reading tip for §15 step 8's `docker compose ps` output: `web`'s container healthcheck
curls `/health/live`, which never touches the database, so `web` stays green throughout a `db`
kill. `/health/ready` is the observable that flips.

The recovery script passes fixture mode to every internal Compose recreation and asserts the
worker's mode after recreation and again before exit. When performing a recovery manually,
carry the mode on every `docker compose up` command and verify it before watching the worker:

```bash
GITHUB_MODE=fixture docker compose up -d --force-recreate worker
docker compose exec worker printenv GITHUB_MODE     # fixture
```

Recovery is also watchable by hand in under a minute — stop the worker, put the entities back
into `pending`, empty the queue (the crash), and start it again:

```bash
docker compose stop worker
docker compose exec db psql -U postgres -d github_push_ingestor_development \
  -c "UPDATE github_actors SET enrichment_status = 'pending', fetched_at = NULL, next_retry_at = NULL;"
docker compose exec db psql -U postgres -d github_push_ingestor_queue_development \
  -c "TRUNCATE solid_queue_jobs CASCADE;"
docker compose start worker
docker compose logs -f worker    # enrichment.dispatched, then enrichment.completed
```

In this scenario, emptying the queue does not discard pending enrichment state: that work is
rebuilt from committed entity rows. This does not claim that arbitrary operational queue
state can be reconstructed.

## Troubleshooting and reset

### Common symptoms

| Symptom | Likely cause | What to run |
|---|---|---|
| No `push_events` after 10 minutes in live mode | Documented 30s–6h feed latency plus the 5-minute cadence — not a fault | `curl -s localhost:3000/status \| jq .sources` |
| Every run reports `globally_blocked` | A `rate_limited` fixture scenario left a real one-hour block | [Recovering from a fixture rate-limit run](#recovering-from-a-fixture-rate-limit-run) |
| Every run reports `source_failed` | A permanent `4xx` took the source out of service | [When a source goes out of service](#when-a-source-goes-out-of-service) |
| `ingest` exits `2` | Unknown option, a refused configuration, or a fixture-corpus gap | `docker compose run --rm ingest --help` |
| Worker logs nothing | `setup` did not complete, so `worker` never started | `docker compose logs setup` |
| `/health/ready` fails while `/health/live` is fine | Database unreachable or schema not loaded. `web`'s healthcheck curls `/health/live`, so `web` stays green through a `db` outage | `docker compose ps`, `docker compose logs db` |
| `up` fails with `Bind for 0.0.0.0:3000 failed: port is already allocated` | Another process owns host port 3000 | Free port 3000, or edit `web`'s `ports:` mapping in `docker-compose.yml` |
| Enrichment stuck at `pending` | The allowance is spent for this window, or the window is not `active` yet | `curl -s localhost:3000/status \| jq .ledger` |

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

### Resetting

Three levels, least destructive first.

**Level 1 — clear derived state, keep the data.** The two SQL blocks above, or both at
once:

```bash
script/verify_recovery.sh --confirm --phase=cleanup
```

**Level 2 — drop the business data, keep the volume.**

```bash
docker compose exec db psql -U postgres -d github_push_ingestor_development -c "
  TRUNCATE push_events, quarantined_events, github_actors, github_repositories,
           ingestion_runs, event_sources, github_api_budget RESTART IDENTITY CASCADE;"
```

Safe because **nothing is seeded**: `Github::Ingestion::SourceProvisioner.ensure!`
recreates the `event_sources` row lazily at the point of use, and
`Github::BudgetLedger#bootstrap!` recreates the ledger row from the next window's response
headers. The next `ingest` behaves exactly like a first run — that is expected, not a
broken system.

**Level 3 — destroy everything, including the volume.**

```bash
docker compose down -v --remove-orphans
if docker volume inspect github-push-ingestor_pgdata >/dev/null 2>&1; then
  echo "github-push-ingestor_pgdata still exists" >&2
  exit 1
fi
docker compose up --build
```

Because the Compose project name is fixed, `pgdata` resolves to the globally named
`github-push-ingestor_pgdata`; every clone on the same Docker host refers to it. `-v` deletes
that volume and **every stored event**. Plain `docker compose down` does not: it stops and
removes the containers and leaves the volume intact, which is why the persistence check finds
identical counts afterward.

## Known limitations

### Expected time before records appear

A push reaches the public feed with a documented latency of 30 seconds to 6 hours,
and the default cadence polls every 5 minutes, so a given push may take hours to
appear — or never, if it left the feed's 300-event window before a poll reached it.
The feed retains 30 days. At `MAX_PAGES_PER_POLL=1` each poll sees at most the
newest ~100 events, and the feed moves considerably faster than that. **This service
samples the public feed rather than mirroring it.**

The nine limitations that follow are consequences of that, of the 60-request hourly
ceiling, and of deliberate scope decisions. Each is a stated operational boundary.

**1. Enrichment has no bounded completion time.** One observed live page held ~92–95
`PushEvent` records with ~89 distinct actors and ~92 distinct repositories — 181 cold
entity requests per page, or ~2,172 an hour if every poll contained entirely new entities,
against 40 available. That extrapolation is a pressure scenario, not the measured
deduplicated arrival rate: repeated actors, repositories, and overlapping pages collapse to
shared rows. Entity rows nevertheless remain durable backlog work, FIFO within each entity
class; quota exhaustion defers them to later windows and never terminates them. If measured
unique arrivals remain above 40 attempts per hour, backlog size and oldest pending age grow
and no finite drain estimate is honest. `/status` publishes backlog count, oldest pending age,
and the reserved allowance's usage; it does not fabricate an ETA from incomplete history.

**2. There is no guarantee of complete upstream capture.** Pagination deepens a single
poll within the budget; it does not backfill. Events that rolled out of the feed's window
while the service was down are **not recoverable**, and no amount of configuration changes
that.

**3. The budget is shared with anything else behind the same outbound IP.** The
unauthenticated limit is IP-keyed, so a co-tenant spends the same sixty requests an hour.
The ledger observes it — `budget.co_tenant_usage`, and `budget.co_tenant_pressure` when
the remaining quota reaches the reserve — and cannot prevent it. See
[Sharing the outbound IP](#sharing-the-outbound-ip).

**4. One event source, in practice.** The event-source seam has two shipped
implementations (live and fixture), and the allowance formula already divides by source
count, but a second *live* source is a documented seam rather than shipped behaviour.

**5. Raw payload retention is semantic, not byte-exact.** Stored as `jsonb`, so whitespace,
key order, and duplicate keys are lost; array order is preserved because it is meaningful
([ADR 0001](docs/adr/0001-jsonb-semantic-retention.md)).

**6. No authentication.** A larger authenticated budget could drain the durable enrichment
backlog faster, but would not make upstream event capture complete. The unauthenticated
constraint is deliberate, not an oversight. See the scaling path in
[`docs/DESIGN_BRIEF.md`](docs/DESIGN_BRIEF.md).

**7. Enriched entities can remain stale while backlog exists.**
`ACTOR_REFRESH_TTL_SECONDS` and `REPOSITORY_REFRESH_TTL_SECONDS` default to 86400, but a
selection that observes never-enriched work does not choose a refresh. Under sustained
backlog pressure, staleness can therefore exceed the TTL; the TTL is an earliest refresh
time, not a deadline. There is one bounded concurrency window: ingestion can commit a new
candidate after fairness has observed both tables empty but before the chosen refresh is
debited. Because a runner cycle issues at most one entity request, at most one refresh can
cross that boundary; the next selection sees the backlog and suppresses refreshes. The race
cannot discard or terminally mark backlog work, and the ledger still enforces the 40-request
enrichment cap.

**8. Extension C (object storage) was deliberately not attempted.** A decision with a
stated reason, not an omission — the remaining budget went to rate-limit correctness,
durability, and reviewer experience. The other optional extensions are implemented:
Extension A (rate limiting and fan-out control) is the class-aware ledger, request gate,
and background processing under [Rate limits and the request
budget](#rate-limits-and-the-request-budget) and [Continuous
ingestion](#continuous-ingestion); Extension B (idempotency and restart safety) is
[Processing guarantees](#processing-guarantees) and [Crash recovery
verification](#crash-recovery-verification); Extension D (testing strategy) is
[Deterministic fixture verification](#deterministic-fixture-verification) and the suite
described there.

**9. Business tables and the enrichment backlog can grow without bound.** `push_events`,
`ingestion_runs`, and `quarantined_events` are append-only, and actor and repository rows
remain actionable until enrichment succeeds or establishes an entity-specific terminal
outcome — this service is the system of record,
and retention, pruning, and archival were deliberately not built. Twelve poll attempts an
hour at up to ~100 events each can add roughly 1,200 event rows and as many as 2,400 entity
references an hour before deduplication, while only 40 enrichment request attempts per hour
are available to work that backlog. The only shipped pruning is Solid Queue's finished-job
cleanup in the queue database, which holds no business data.

## Development

AI-assisted development guidance for this repository lives in
[`CLAUDE.md`](CLAUDE.md).

- [`docs/DESIGN_BRIEF.md`](docs/DESIGN_BRIEF.md) — the two-page architecture summary; start
  here.
- [`docs/adr/`](docs/adr/) — twelve architecture decision records.
- [`docs/evidence/`](docs/evidence/) — dated first-party verifications of contested claims.
- [`docs/SUBMISSION_CHECKLIST.md`](docs/SUBMISSION_CHECKLIST.md) — the §16 quality gates as
  a pre-flight checklist.
- [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) — the execution plan; Appendix E
  records build-time divergence and Appendix F the durable-backlog correction.

## License

[MIT](LICENSE)
