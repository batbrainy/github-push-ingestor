# Container-kill recovery verification

Date: 2026-07-31

Status: Historical first-party observation; superseded for submission gating

> [!CAUTION]
> **Erratum — do not use the green verdict in this file as the submission gate.** The script
> revision that produced the raw transcript suppressed non-zero fixture ingestion and
> enrichment exits with `|| true`, printed `push_events` counts without asserting equality
> after every recovery, and did not carry `GITHUB_MODE=fixture` into every Compose
> recreation. A recreated worker could therefore default to live mode and spend GitHub
> budget. The transcript is preserved verbatim below as a historical observation. Re-run the
> corrected script against the final default-branch SHA and record that result in the
> external findings report. That re-run is now recorded:
> [`2026-08-01-post-merge-verification.md`](2026-08-01-post-merge-verification.md) gate 1.18
> ran the corrected script against `88e2260c` — 45 checks passed, 0 failed.

> [!IMPORTANT]
> The raw transcript also predates the 2026-08-02 durable-backlog correction. Its
> `enrichment.aged_out` and skipped-count lines describe the old binary, not current policy.
> Current entity work is never terminally skipped for quota; see
> [`IMPLEMENTATION_PLAN.md` Appendix F](../../IMPLEMENTATION_PLAN.md).

## Why this verification exists

`IMPLEMENTATION_PLAN.md` §2A declares `restart: unless-stopped` on `db`, `web` and `worker`,
and §16 turns that declaration into a durability gate whose wording is deliberately strong:
"Docker restart policies recover crashed `db`/`web`/`worker` containers automatically
**(verified by container kills)**". §15 step 8 gives the reviewer the commands.

Until something kills a container, all of that is a line of YAML.
`spec/docker_compose_spec.rb` asserts the *declarations* — that `db` keeps a named volume,
that `web` runs puma directly so no pid file can survive an ungraceful kill, that no service
leaves `restart` implicit — and `spec/recovery/` asserts the crash-window *state machine*.
Neither can observe Docker's restart policy, because no RSpec example can kill the process it
is running inside. This is the observation that closes that gap.

## The finding

**§15 step 8's own command does not exercise the restart policy, and never could.**

`docker kill` is an API stop. The daemon records the container as manually stopped, and
`restart: unless-stopped` is defined to skip exactly that case — that is what "unless stopped"
means. Measured below, each of the three services stayed down after `docker kill` with
`RestartCount` unchanged at 0. A reviewer following the plan literally would watch three
containers die, see none of them come back, and conclude the durability gate is unmet.

The policy itself is sound. When the container's main process is killed the way a real crash
kills it — SIGKILL delivered from outside the container's PID namespace, which the daemon does
not attribute to an operator — every service came back on its own, with `RestartCount`
incrementing and no operator step.

So the two facts are separate and both belong in the record:

| Service | `docker kill` (§15 step 8) | process crash |
|---|---|---|
| `worker` | stays down, `RestartCount` 0 → 0 | restarts itself, 0 → 1 |
| `db` | stays down, `RestartCount` 0 → 0 | restarts itself, 0 → 1 |
| `web` | stays down, `RestartCount` 0 → 0 | restarts itself, 0 → 1 |

`script/verify_recovery.sh` therefore kills each service twice and reports both, rather than
quietly substituting the kill that works. A reviewer typing §15's command should be told what
they are about to see.

Note that an in-container kill is not an alternative: the kernel refuses to deliver SIGKILL to
a PID namespace's own init from inside that namespace, so `docker exec … kill -9 1` is a no-op.
The helper runs `--pid=host --privileged --user 0`; the `--user 0` is load-bearing, because the
application image declares a non-root user which cannot signal postgres.

## What else was measured

- **Records survived.** `push_events` read 9,293 before the worker kill and 9,293 after every
  kill, restart and recovery in this run. PostgreSQL replayed its WAL onto the same volume.
- **The volume is the same volume.** `github-push-ingestor_pgdata`'s `CreatedAt` is identical at
  preflight and at the end, so the counts above are survival rather than recreation.
- **§16's test-isolation gate holds at runtime.** `docker compose run --rm test` left both
  development databases byte-identical (`push_events` 9,293 and `solid_queue_jobs` 1,703 on
  both sides) and did not trigger the development `setup` service. The worker is stopped for
  the duration of that measurement and restarted after: it is the only other writer to those
  tables, and a fixture poll landing mid-suite would otherwise move both counters and make the
  comparison meaningless. An earlier revision of this script did not stop it, recorded
  `push_events` climbing 263 → 353, and still printed that the gate held — the check now fails
  the run instead.
- **Fixture mode failed closed in the running stack.** This development database holds entities
  from earlier live polls, whose `api_url`s are absent from the corpus. The fixture-mode
  enrichment cycle refused with a corpus gap and exit 2 rather than reaching `api.github.com`.
  That is §6's rule observed in a container, which no unit test can show.
- **Both redirect corpus scenarios ran end to end, with a verdict.** `redirecting_repository`
  left the corpus repository `complete` across a validated hop; `hostile_redirect` left it
  `permanent_failure` with the second hop never sent. Selection is forced first — §10 picks the
  newest eligible candidate, and on a database that has polled live GitHub that is a real
  repository the corpus has never heard of, so an earlier revision of this script watched both
  scenarios die on a corpus gap while `|| true` swallowed the exit code.

## What this does not show

- One host, one operating system, one Docker version, one date. Docker's treatment of
  `docker kill` is a daemon behaviour and could differ on another version; the commands to
  re-measure it are below.
- `unless-stopped` is **not** exercised here across a Docker daemon restart or a host reboot,
  which is the other half of what the policy promises.
- A SIGKILL to postgres exercises WAL crash recovery, not disk corruption, not a failing
  volume, and not a full disk.
- The worker ran in fixture mode, whose sticky-tail `304` is what makes "the count is
  unchanged" a stable expectation. A live stack's count would legitimately grow between the two
  measurements, and this transcript says nothing about that case.
- **No kill here was deliberately timed inside an in-flight `push_events` insert.** That
  guarantee is not observable from outside the process and is asserted instead by
  `spec/recovery/crash_window_spec.rb`, which composes a held source lock, an abandoned
  enrichment lease and a lost enqueue into one restart.
- `docker kill` is not an OOM kill, not a power loss, and not a kernel panic.
- The counts are read as deltas, not against the README's documented absolutes (4 / 3 / 3 / 3),
  because this database was not started from an empty volume. `script/verify_recovery.sh`
  detects that and says which mode it used.
- The redirect scenarios are exercised against one seeded row, so what they show is the
  outcome for *that* repository rather than a property of the selection policy. The policy
  itself is asserted in `spec/services/github/enrichment/redirect_boundary_spec.rb`.

## Every check reported by this historical run

This run reported **19 checks, all passing**. That is what the preserved transcript says, not
a current submission verdict: the erratum above identifies failures that were outside those
19 checks or whose exit statuses were suppressed.

## Reproducing it

```bash
GITHUB_MODE=fixture docker compose up --build -d
GITHUB_MODE=fixture script/verify_recovery.sh --confirm
docker compose exec worker printenv GITHUB_MODE   # must print fixture
```

The corrected script refuses to run under `CI`, without `--confirm`, against a stack whose
worker is not in fixture mode, with `RAILS_ENV` set to anything but `development`, or when the
container names do not match the literals §15 uses. It passes fixture mode to every internal
Compose invocation, checks every fixture command's status, asserts `push_events` equality,
and verifies the recreated worker is still offline. It never runs `docker compose down`,
never drops a database, and never issues psql against a `_test` database.

The two kill paths remain intentionally distinct. `docker kill` asks the Docker API to stop a
container, so it is a negative control and `restart: unless-stopped` leaves the container
down. The host-PID-namespace kill terminates the main process without recording an operator
stop; that process-crash path must restart automatically.

Nothing in the suite, in `config/ci.rb`, in `bin/ci` or in the workflows executes it —
`spec/docker_compose_spec.rb` asserts that, so "CI never runs the verification" is a red test
rather than a promise.

## Raw historical transcript — preserved verbatim

Captured by `script/verify_recovery.sh` on the date above. `login`, `display_login`,
`full_name`, `api_url`, `avatar_url` and the corpus-miss payload are redacted in place — names
kept, values removed — because a development database that has polled live GitHub holds real
third-party account and repository names that no finding here needs.

<!-- Generated by script/verify_recovery.sh on 2026-07-31T11:58:08Z -->

```text
Verification date:  2026-07-31
Compose project:    github-push-ingestor
Git revision:       ac5cf989393e28dc5e85058647816c3aa00927e6
Docker version:     28.3.0
Compose version:    2.38.1-desktop.1
Host:               Darwin 25.5.0 arm64
Worker mode:        fixture (enforced by preflight)
Count mode:         delta
Captured by:        script/verify_recovery.sh
Redaction:          login, display_login, full_name, api_url, avatar_url and the corpus-miss
                    payload are replaced in place; names kept, values removed
```

## Baseline

```
 Container github-push-ingestor-db-1  Running
 Container github-push-ingestor-db-1  Waiting
 Container github-push-ingestor-db-1  Healthy
 Container github-push-ingestor-setup-1  Starting
 Container github-push-ingestor-setup-1  Started
{"timestamp":"2026-07-31T11:58:11.177Z","level":"info","service":"github-push-ingestor","environment":"development","event":"config.budget_resolved","mode":"fixture","poll_interval_seconds":300,"max_pages_per_poll":1,"enabled_live_source_count":1,"worst_case_reservations_per_poll":9,"limit":60,"reserve":8,"poll_allowance":12,"enrichment_allowance":40,"actor_guarantee":20,"repository_guarantee":20}
{"timestamp":"2026-07-31T11:58:11.373Z","level":"info","service":"github-push-ingestor","environment":"development","event":"ingestion.not_due","event_source_id":1,"forced":false,"deferral_reason":"cadence_due_at","next_poll_at":"2026-07-31T12:03:00Z","cadence_due_at":"2026-07-31T12:03:00Z","poll_floor_until":"2026-07-31T11:59:00Z"}
Ingestion deferred until 2026-07-31T12:03:00Z — cadence_due_at

Latest successful run:            2026-07-31T11:58:00Z (run_id 01c3ca5b-2af6-4e89-9db9-3daed35148e4)
Persisted push events:            9,293
Pending actor enrichments:        1,313
Pending repository enrichments:   1,375
Next poll due:                    2026-07-31T12:03:00Z
Budget remaining (core):          59 (window resets 2026-07-31T12:58:00Z)
Global block:                     none
```

```
 Container github-push-ingestor-db-1  Running
 Container github-push-ingestor-db-1  Waiting
 Container github-push-ingestor-db-1  Healthy
 Container github-push-ingestor-setup-1  Starting
 Container github-push-ingestor-setup-1  Started
{"timestamp":"2026-07-31T11:58:13.633Z","level":"info","service":"github-push-ingestor","environment":"development","event":"config.budget_resolved","mode":"fixture","poll_interval_seconds":300,"max_pages_per_poll":1,"enabled_live_source_count":1,"worst_case_reservations_per_poll":9,"limit":60,"reserve":8,"poll_allowance":12,"enrichment_allowance":40,"actor_guarantee":20,"repository_guarantee":20}
{"timestamp":"2026-07-31T11:58:13.814Z","level":"info","service":"github-push-ingestor","environment":"development","event":"enrichment.aged_out","entity_type":"actor","skipped_count":467,"batch_size":1000,"eligible_since":"2026-07-31T10:58:13Z"}
{"timestamp":"2026-07-31T11:58:13.822Z","level":"info","service":"github-push-ingestor","environment":"development","event":"enrichment.aged_out","entity_type":"repository","skipped_count":493,"batch_size":1000,"eligible_since":"2026-07-31T10:58:13Z"}
Fixture corpus error: the corpus defines no response for "<redacted>"
Actors pending/complete/skipped:  846 / 271 / 5,528
Repos pending/complete/skipped:   882 / 267 / 5,844
Actor requests used:              1 of 20
Repository requests used:         0 of 20
Enrichment requests used:         1 of 40
Next enrichment due:              due now

Latest successful run:            2026-07-31T11:58:00Z (run_id 01c3ca5b-2af6-4e89-9db9-3daed35148e4)
Persisted push events:            9,293
Pending actor enrichments:        846
Pending repository enrichments:   882
Next poll due:                    2026-07-31T12:03:00Z
Budget remaining (core):          58 (window resets 2026-07-31T12:58:00Z)
Global block:                     none

```

A corpus gap above is not a fault. It means this development database holds entities
from an earlier live run, and fixture mode refused to fetch them rather than falling
back to the network — exit 2, "refused to run", per §9's exit-code contract.

The development database already held 9293 push events at the start of this
run, so the counts below are read as deltas. The README's documented absolutes
(4 / 3 / 3 / 3 / 3) apply only to a stack started from an empty volume.

| measurement              | push_events | actors | repositories | quarantined | occurrences |
| ------------------------ | --- | --- | --- | --- | --- |
| baseline                 | 9293 | 6646 | 6994 | 3 | 24 |

## Worker kill (§15 step 8)

Count before the kill: push_events = 9293

### Part 1 — the command §15 documents

$ docker kill github-push-ingestor-worker-1

$ docker compose ps
```
NAME                         IMAGE                      COMMAND                  SERVICE   CREATED          STATUS                    PORTS
github-push-ingestor-db-1    postgres:16                "docker-entrypoint.s…"   db        22 hours ago     Up 9 hours (healthy)      5432/tcp
github-push-ingestor-web-1   github-push-ingestor-app   "bundle exec puma -C…"   web       55 seconds ago   Up 52 seconds (healthy)   0.0.0.0:3000->3000/tcp, [::]:3000->3000/tcp
```

| after `docker kill` | value |
| --- | --- |
| Running | false |
| ExitCode | 137 |
| RestartCount | 0 -> 0 |

- PASS — docker kill leaves worker down, because an API stop skips the restart policy
- PASS — docker kill does not increment worker's RestartCount

`docker kill` is an API stop, so the daemon records the container as manually stopped
and `restart: unless-stopped` does not apply. The container stays down and an operator
step is required to bring it back — which is what the next command is.

$ docker compose up -d worker

### Part 2 — a process crash, which is what the policy is for

$ docker run --rm --pid=host --privileged --user 0 github-push-ingestor-app sh -c 'kill -9 71866'

| after a process crash | value |
| --- | --- |
| Running | true |
| RestartCount | 0 -> 1 |
| StartedAt | 2026-07-31T11:58:27.985033422Z -> 2026-07-31T11:58:28.817818464Z |

- PASS — worker was restarted by its policy after a process crash
- PASS — worker's RestartCount incremented

Docker restarted `worker` on its own. No operator step.

$ docker compose logs worker --since 2m
```
{"timestamp":"2026-07-31T11:58:29.241Z","level":"info","service":"github-push-ingestor","environment":"development","event":"config.budget_resolved","mode":"live","poll_interval_seconds":300,"max_pages_per_poll":1,"enabled_live_source_count":1,"worst_case_reservations_per_poll":9,"limit":60,"reserve":8,"poll_allowance":12,"enrichment_allowance":40,"actor_guarantee":20,"repository_guarantee":20}
{"timestamp":"2026-07-31T11:58:29.524Z","level":"info","service":"github-push-ingestor","environment":"development","message":"SolidQueue-1.5.1 Started Supervisor(fork) (27.1ms)  pid: 1, hostname: \"07576a1f31d4\", process_id: 255, name: \"supervisor(fork)-a08de2f018029095efd5\""}
{"timestamp":"2026-07-31T11:58:29.552Z","level":"info","service":"github-push-ingestor","environment":"development","message":"SolidQueue-1.5.1 Started Dispatcher (25.1ms)  pid: 11, hostname: \"07576a1f31d4\", process_id: 256, name: \"dispatcher-b0a6d73b6ac91683b3d1\", polling_interval: 1, batch_size: 500, concurrency_maintenance_interval: 600"}
{"timestamp":"2026-07-31T11:58:29.552Z","level":"info","service":"github-push-ingestor","environment":"development","message":"SolidQueue-1.5.1 Started Worker (23.3ms)  pid: 15, hostname: \"07576a1f31d4\", process_id: 257, name: \"worker-34a3ed5d4550b3bab3ab\", polling_interval: 1, queues: \"*\", thread_pool_size: 2"}
{"timestamp":"2026-07-31T11:58:29.563Z","level":"info","service":"github-push-ingestor","environment":"development","message":"SolidQueue-1.5.1 Started Scheduler (31.8ms)  pid: 19, hostname: \"07576a1f31d4\", process_id: 258, name: \"scheduler-01c7cc9291d0c3c23e7f\", recurring_schedule: [\"poll_event_sources\", \"reconcile_pending_enrichments\", \"clear_solid_queue_finished_jobs\"]"}
```

Count after recovery: push_events = 9293

## Database kill (§15 step 8)

Count before the kill: push_events = 9293

### Part 1 — the command §15 documents

$ docker kill github-push-ingestor-db-1

$ docker compose ps
```
NAME                            IMAGE                      COMMAND                  SERVICE   CREATED              STATUS                         PORTS
github-push-ingestor-web-1      github-push-ingestor-app   "bundle exec puma -C…"   web       About a minute ago   Up About a minute (healthy)    0.0.0.0:3000->3000/tcp, [::]:3000->3000/tcp
github-push-ingestor-worker-1   github-push-ingestor-app   "bin/jobs"               worker    14 seconds ago       Restarting (1) 2 seconds ago
```

| after `docker kill` | value |
| --- | --- |
| Running | false |
| ExitCode | 137 |
| RestartCount | 0 -> 0 |

- PASS — docker kill leaves db down, because an API stop skips the restart policy
- PASS — docker kill does not increment db's RestartCount

`docker kill` is an API stop, so the daemon records the container as manually stopped
and `restart: unless-stopped` does not apply. The container stays down and an operator
step is required to bring it back — which is what the next command is.

$ docker compose up -d db

### Part 2 — a process crash, which is what the policy is for

$ docker run --rm --pid=host --privileged --user 0 github-push-ingestor-app sh -c 'kill -9 72842'

| after a process crash | value |
| --- | --- |
| Running | true |
| RestartCount | 0 -> 1 |
| StartedAt | 2026-07-31T11:58:41.025798345Z -> 2026-07-31T11:58:47.519682667Z |

- PASS — db was restarted by its policy after a process crash
- PASS — db's RestartCount incremented

Docker restarted `db` on its own. No operator step.

Count after recovery: push_events = 9293

- PASS — push_events is unchanged across two SIGKILLs of the database

PostgreSQL replayed its WAL onto the same named volume, which is §15 step 8's actual
question.

## Web kill (beyond §15's list — verifies the Dockerfile's pid-file claim)

§16's durability gate names db, web and worker; §15 step 8 kills only two. The
Dockerfile runs puma directly rather than `bin/rails server` so that a stale
tmp/pids/server.pid left by an ungraceful kill cannot block the restart
`unless-stopped` promises — and a crash is the only thing that exercises it.

### Part 1 — the command §15 documents

$ docker kill github-push-ingestor-web-1

$ docker compose ps
```
NAME                            IMAGE                      COMMAND                  SERVICE   CREATED          STATUS                    PORTS
github-push-ingestor-db-1       postgres:16                "docker-entrypoint.s…"   db        22 hours ago     Up 16 seconds (healthy)   5432/tcp
github-push-ingestor-worker-1   github-push-ingestor-app   "bin/jobs"               worker    38 seconds ago   Up 17 seconds             3000/tcp
```

| after `docker kill` | value |
| --- | --- |
| Running | false |
| ExitCode | 137 |
| RestartCount | 0 -> 0 |

- PASS — docker kill leaves web down, because an API stop skips the restart policy
- PASS — docker kill does not increment web's RestartCount

`docker kill` is an API stop, so the daemon records the container as manually stopped
and `restart: unless-stopped` does not apply. The container stays down and an operator
step is required to bring it back — which is what the next command is.

$ docker compose up -d web

### Part 2 — a process crash, which is what the policy is for

$ docker run --rm --pid=host --privileged --user 0 github-push-ingestor-app sh -c 'kill -9 73745'

| after a process crash | value |
| --- | --- |
| Running | true |
| RestartCount | 0 -> 1 |
| StartedAt | 2026-07-31T11:59:06.570479551Z -> 2026-07-31T11:59:08.565763093Z |

- PASS — web was restarted by its policy after a process crash
- PASS — web's RestartCount incremented

Docker restarted `web` on its own. No operator step.

`/health/live` and `/health/ready` both answer again after an uncooperative kill, so no
pid file survived to block the restart.

## Normal restart (§15 step 9)

$ docker compose restart
```
```

Took 1s. The worker's `stop_grace_period: 30s` is a ceiling, not a duration:
Solid Queue's supervisor acknowledges SIGTERM and exits well inside it whenever no
GitHub request is in flight, and in fixture mode none ever is for long.

push_events before: 9293, after: 9293

## Test isolation (§16's reviewer-experience gate)

§16 requires that `docker compose run --rm test` never touches the development
databases (app or queue) and never triggers the development `setup` service.
spec/docker_compose_spec.rb asserts the declarations; this measures the behaviour.

$ docker compose stop worker    # the only other writer to these databases

```
  the reserve
    stops every class at the reserve, however many callers are in flight

Finished in 0.92454 seconds (files took 0.41603 seconds to load)
10 examples, 0 failures

Randomized with seed 18641

```

$ docker compose start worker

| observable | before | after |
| --- | --- | --- |
| development push_events | 9293 | 9293 |
| development solid_queue_jobs | 1703 | 1703 |
| setup container FinishedAt | 2026-07-31T11:59:11.267659511Z | 2026-07-31T11:59:11.267659511Z |

- PASS — the suite left development push_events untouched
- PASS — the suite left the development queue untouched
- PASS — the suite did not trigger the development setup service

## Deterministic fixture scenarios (§15 step 10)

The full nine-scenario matrix is documented in the README; this phase runs the two
the transcript can prove without waiting. Every ingestion obeys GitHub's
`X-Poll-Interval` floor of 60s, which `--force` deliberately does not bypass, so
back-to-back poll scenarios are a README exercise rather than a script phase. The
redirect scenarios go through `bin/enrich`, which has no cadence.

$ docker compose stop worker    # so nothing re-orders the candidate set mid-scenario

### redirecting_repository — a validated redirect is followed and the entity completes

```
 Container github-push-ingestor-db-1  Running
 Container github-push-ingestor-setup-1  Recreate
 Container github-push-ingestor-setup-1  Recreated
 Container github-push-ingestor-db-1  Waiting
 Container github-push-ingestor-db-1  Healthy
 Container github-push-ingestor-setup-1  Starting
 Container github-push-ingestor-setup-1  Started
{"timestamp":"2026-07-31T11:59:46.289Z","level":"info","service":"github-push-ingestor","environment":"development","event":"config.budget_resolved","mode":"fixture","poll_interval_seconds":300,"max_pages_per_poll":1,"enabled_live_source_count":1,"worst_case_reservations_per_poll":9,"limit":60,"reserve":8,"poll_allowance":12,"enrichment_allowance":40,"actor_guarantee":20,"repository_guarantee":20}
{"timestamp":"2026-07-31T11:59:46.497Z","level":"info","service":"github-push-ingestor","environment":"development","event":"budget.window_rolled","carried_forward":"repository","limit":60,"reserve":8,"poll_allowance":12,"enrichment_allowance":40,"actor_guarantee":20,"repository_guarantee":20}
{"timestamp":"2026-07-31T11:59:46.498Z","level":"info","service":"github-push-ingestor","environment":"development","event":"budget.window_initialized","limit":60,"reserve":8,"poll_allowance":12,"enrichment_allowance":40,"actor_guarantee":20,"repository_guarantee":20,"rate_limit_resource":"core","rate_limit_limit":60,"rate_limit_remaining":54,"rate_limit_used":6,"rate_limit_reset_at":"2026-07-31T12:59:46Z","poll_used":0}
{"timestamp":"2026-07-31T11:59:46.505Z","level":"info","service":"github-push-ingestor","environment":"development","enrichment_outcome":"enriched","entity_type":"repository","github_id":1296269,"pool":"pending","classification":"ok","entity_status":"complete","enrichment_attempt":1,"duration_ms":71.8,"event":"enrichment.completed"}
Enriched repository 1296269 — complete

Enrichment cycles:                1
Entities enriched:                1
Entities failed:                  0
Cycles deferred:                  0
Cycles with nothing eligible:     0
Candidates skipped (budget):      0

Actors pending/complete/skipped:  845 / 272 / 5,528
Repos pending/complete/skipped:   881 / 269 / 5,843
Actor requests used:              0 of 20
Repository requests used:         2 of 20
Enrichment requests used:         2 of 40
Next enrichment due:              due now

Latest successful run:            2026-07-31T11:58:00Z (run_id 01c3ca5b-2af6-4e89-9db9-3daed35148e4)
Persisted push events:            9,293
Pending actor enrichments:        845
Pending repository enrichments:   881
Next poll due:                    2026-07-31T12:03:00Z
Budget remaining (core):          53 (window resets 2026-07-31T12:59:46Z)
Global block:                     none
```

- PASS — redirecting_repository left the corpus repository complete

### hostile_redirect — an off-host redirect is refused by the URL policy

```
 Container github-push-ingestor-db-1  Running
 Container github-push-ingestor-setup-1  Recreate
 Container github-push-ingestor-setup-1  Recreated
 Container github-push-ingestor-db-1  Waiting
 Container github-push-ingestor-db-1  Healthy
 Container github-push-ingestor-setup-1  Starting
 Container github-push-ingestor-setup-1  Started
{"timestamp":"2026-07-31T11:59:49.923Z","level":"info","service":"github-push-ingestor","environment":"development","event":"config.budget_resolved","mode":"fixture","poll_interval_seconds":300,"max_pages_per_poll":1,"enabled_live_source_count":1,"worst_case_reservations_per_poll":9,"limit":60,"reserve":8,"poll_allowance":12,"enrichment_allowance":40,"actor_guarantee":20,"repository_guarantee":20}
{"timestamp":"2026-07-31T11:59:50.120Z","level":"info","service":"github-push-ingestor","environment":"development","event":"budget.window_rolled","carried_forward":"repository","limit":60,"reserve":8,"poll_allowance":12,"enrichment_allowance":40,"actor_guarantee":20,"repository_guarantee":20}
{"timestamp":"2026-07-31T11:59:50.121Z","level":"info","service":"github-push-ingestor","environment":"development","event":"budget.window_initialized","limit":60,"reserve":8,"poll_allowance":12,"enrichment_allowance":40,"actor_guarantee":20,"repository_guarantee":20,"rate_limit_resource":"core","rate_limit_limit":60,"rate_limit_remaining":54,"rate_limit_used":6,"rate_limit_reset_at":"2026-07-31T12:59:50Z","poll_used":0}
{"timestamp":"2026-07-31T11:59:50.122Z","level":"warn","service":"github-push-ingestor","environment":"development","event":"github.request","request_class":"repository","http_method":"get","url":"https://evil.example.com/repos/octocat/Hello-World","origin":"payload","entity_type":"repository","github_repository_id":1296269,"pool":"pending","entity_status":"pending","enrichment_attempt":1,"classification":"permanent_error","attempt":0,"duration_ms":0.0,"error_class":"Github::Errors::UrlPolicyViolation","error_message":"refused \"https://evil.example.com/repos/octocat/Hello-World\": host_not_allowed"}
{"timestamp":"2026-07-31T11:59:50.124Z","level":"info","service":"github-push-ingestor","environment":"development","enrichment_outcome":"failed","entity_type":"repository","github_id":1296269,"pool":"pending","classification":"permanent_error","entity_status":"permanent_failure","enrichment_attempt":1,"error_message":"refused \"https://evil.example.com/repos/octocat/Hello-World\": host_not_allowed","duration_ms":50.8,"event":"enrichment.failed"}
Repository 1296269 permanent_failure: refused "https://evil.example.com/repos/octocat/Hello-World": host_not_allowed

Enrichment cycles:                1
Entities enriched:                0
Entities failed:                  1
Cycles deferred:                  0
Cycles with nothing eligible:     0
Candidates skipped (budget):      0

Actors pending/complete/skipped:  845 / 272 / 5,528
Repos pending/complete/skipped:   881 / 268 / 5,843
Actor requests used:              0 of 20
Repository requests used:         1 of 20
Enrichment requests used:         1 of 40
Next enrichment due:              due now

Latest successful run:            2026-07-31T11:58:00Z (run_id 01c3ca5b-2af6-4e89-9db9-3daed35148e4)
Persisted push events:            9,293
Pending actor enrichments:        845
Pending repository enrichments:   881
Next poll due:                    2026-07-31T12:03:00Z
Budget remaining (core):          54 (window resets 2026-07-31T12:59:50Z)
Global block:                     none
```

- PASS — hostile_redirect left the corpus repository permanent_failure

$ docker compose start worker

| measurement              | push_events | actors | repositories | quarantined | occurrences |
| ------------------------ | --- | --- | --- | --- | --- |
| after scenarios          | 9293 | 6646 | 6994 | 3 | 24 |

## Volume identity

`github-push-ingestor_pgdata` CreatedAt at preflight: 2026-07-30T13:38:59Z
`github-push-ingestor_pgdata` CreatedAt now:          2026-07-30T13:38:59Z

- PASS — the pgdata volume is the same volume it was at preflight

Identical means the records above *survived* the kills rather than being recreated
into a fresh volume, which is what makes the counts evidence rather than coincidence.

## Verdict

Every check above passed.

Paste the above into docs/evidence/$(date -u +%Y-%m-%d)-container-kill-recovery.md and
write the finding and the "What this does not show" section by hand.
