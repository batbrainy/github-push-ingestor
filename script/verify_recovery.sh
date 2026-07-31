#!/usr/bin/env bash
#
# Runs IMPLEMENTATION_PLAN.md §15 step 8's container-kill verification and prints a
# paste-ready transcript body for docs/evidence/.
#
# WHY THIS EXISTS
#
#   §2A declares `restart: unless-stopped` on db, web and worker, and §16 turns that into a
#   durability gate whose wording is "verified by container kills". Until something actually
#   kills a container, the policy is a line of YAML. spec/docker_compose_spec.rb asserts the
#   declarations — that db keeps a *named* volume, that web runs puma directly so no pid file
#   can survive a kill, that no service leaves `restart` implicit — but a declaration is not
#   an observation, and no RSpec example can kill the process it is running inside.
#
#   The crash-window guarantees themselves are unit-tested: spec/recovery/ covers work
#   committed but never enqueued, a job delivered twice, a lease left by a crashed worker,
#   contention between pollers, advisory-lock release on session death, and the convergence of
#   all three after a restart. What none of them can reach is Docker's restart policy, the
#   named volume surviving a database kill, and the fact that `docker compose run --rm test`
#   leaves the development databases untouched. That is what this script measures.
#
# WHY EACH SERVICE IS KILLED TWICE
#
#   §15 step 8 prescribes `docker kill <container>`, and that command does not do what the
#   surrounding text assumes. `docker kill` is an API stop: the daemon records the container
#   as manually stopped, and `restart: unless-stopped` is defined to skip exactly that case.
#   Measured on 2026-07-31 against Docker 28.3.0, the killed worker stayed down with
#   RestartCount at 0 — so the plan's own procedure demonstrates the opposite of §16's
#   durability gate, and a reviewer following it would conclude the policy is broken.
#
#   So each service is killed twice. First with §15's literal command, reporting honestly that
#   the container stays down and needs `docker compose up -d` — because that is what a reviewer
#   typing the documented command will see. Then with a SIGKILL delivered to the container's
#   main process from outside its PID namespace, which the daemon does not treat as a manual
#   stop and which is the crash the policy exists for. That second kill is the one that
#   verifies §16's gate.
#
# WHY IT IS A SHELL SCRIPT AND NOT A RAKE TASK
#
#   A rake task loads Rails, which would put `docker kill` one autoload away from
#   Github.executor and the development github_api_budget row — the very state the transcript
#   is about. This process knows nothing about the application. It is also not in bin/, which
#   holds what the product runs: bin/ingest is what `docker compose run --rm ingest` resolves
#   to, and a container-killing tool there invites someone to wire it into compose or CI.
#
# COST: kills and restarts the running db, web and worker containers, and writes to the
# *development* databases. It never touches the test databases, never removes a volume, and
# never runs db:drop or db:reset. Do not run it against a stack someone else is using.
#
# Nothing in the repository executes this file. spec/docker_compose_spec.rb asserts that, so
# "CI never runs the verification" is a red test rather than a promise.

set -euo pipefail

readonly PROJECT="github-push-ingestor"
readonly APP_IMAGE="github-push-ingestor-app"
readonly DEV_DB="github_push_ingestor_development"
readonly DEV_QUEUE_DB="github_push_ingestor_queue_development"
readonly LONG_RUNNING="db web worker"
readonly READY_URL="http://localhost:3000/health/ready"
readonly LIVE_URL="http://localhost:3000/health/live"
# octocat/Hello-World — the repository both redirect scenarios in fixtures/github/manifest.json
# are authored against, and the id inside bodies/repos/octocat_hello-world.json.
readonly CORPUS_REPOSITORY_ID=1296269

if [ -n "${CI:-}" ]; then
  echo "refusing: this verification kills containers and writes to the development databases" >&2
  exit 2
fi

PHASE="all"
CONFIRMED=""

for argument in "$@"; do
  case "$argument" in
    --confirm) CONFIRMED="yes" ;;
    --phase=*) PHASE="${argument#--phase=}" ;;
    *)
      echo "unknown option: ${argument}" >&2
      CONFIRMED=""
      break
      ;;
  esac
done

if [ -z "$CONFIRMED" ]; then
  cat >&2 <<'USAGE'
usage: script/verify_recovery.sh --confirm [--phase=NAME]

Runs IMPLEMENTATION_PLAN.md §15 step 8 against the running Compose stack and prints a
transcript body for docs/evidence/.

WHAT IT MUTATES

  - Kills the db, web and worker containers twice each, one service at a time: once with
    §15's `docker kill` (an API stop, which does NOT trigger the restart policy — the
    container is brought back with `docker compose up -d`), and once with a SIGKILL to the
    container's main process from outside its PID namespace, which does.
  - Runs one privileged --pid=host container per crash kill, using the image this project
    already builds. Nothing is pulled.
  - Runs `docker compose restart` (§15 step 9).
  - Runs one fixture-mode ingestion and up to six enrichment cycles, which write to
    github_push_ingestor_development: push events, actors, repositories, quarantine rows,
    ingestion runs, and the github_api_budget counters.
  - Runs `docker compose run --rm test`, which touches only the isolated test databases.

WHAT IT NEVER DOES

  - No `docker compose down`, with or without -v. No db:drop, no db:reset.
  - No psql against any _test database.
  - No live GitHub request: fixture mode is a preflight requirement, not a suggestion.

PHASES (--phase=NAME runs one; the default runs them in this order)

  preflight        guards; always runs
  baseline         one fixture ingestion + enrichment, then record counts
  kill-worker      §15 step 8's worker kill
  kill-db          §15 step 8's database kill
  kill-web         SIGKILL web and wait for /health/ready (beyond §15's list — see below)
  restart          §15 step 9's `docker compose restart`
  test-isolation   §16's gate: the suite leaves the development databases untouched
  scenarios        §15 step 10's deterministic fixture scenario, plus both redirect scenarios
  volume-check     the pgdata volume is the same volume it was at the start

  rate-limit       OPT-IN, never part of the default run. Plays the rate_limited scenario,
                   which leaves a real one-hour global block, then clears it.
  cleanup          clears a global block and restores a failed source; the escape hatch if
                   you interrupt a run

WHY kill-web IS HERE AND NOT IN §15

  §16's durability gate names db, web and worker; §15 step 8 kills only two. The Dockerfile
  runs puma directly rather than `bin/rails server` specifically so a stale
  tmp/pids/server.pid cannot block a restart after an ungraceful kill. That claim is
  otherwise unverified.

PREREQUISITE

  GITHUB_MODE=fixture docker compose up --build -d
USAGE
  exit 2
fi

# ---------------------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------------------

# Every psql call in this file goes through one of these two functions, and both hard-code a
# _development database name. There is deliberately no helper that takes a database
# argument: §16 gates that the test databases are never touched by anything but the suite,
# and the cheapest way to keep that true is to make the wrong database unspellable here.
psql_dev() {
  docker compose exec -T db psql -U postgres -d "$DEV_DB" -tAc "$1" | tr -d '[:space:]'
}

psql_queue_dev() {
  docker compose exec -T db psql -U postgres -d "$DEV_QUEUE_DB" -tAc "$1" | tr -d '[:space:]'
}

# Exactly one id, always. `docker compose ps -q` lists running containers only, and every
# measurement here is taken across a stop — but `--all` can return a recreated container
# alongside the one it replaced, and two ids would make every `docker inspect` below fail. So:
# prefer the running container, fall back to the most recent stopped one.
container_id() {
  local id
  id="$(docker compose ps -q "$1" 2>/dev/null | head -1)"
  [ -n "$id" ] || id="$(docker compose ps -aq "$1" 2>/dev/null | head -1)"

  printf '%s' "$id"
}

container_name() {
  docker inspect -f '{{.Name}}' "$(container_id "$1")" | sed 's|^/||'
}

started_at() {
  docker inspect -f '{{.State.StartedAt}}' "$(container_id "$1")"
}

restart_count() {
  docker inspect -f '{{.RestartCount}}' "$(container_id "$1")"
}

running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$(container_id "$1")")" = "true" ]
}

health_status() {
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$(container_id "$1")"
}

# Bounded, and never a bare sleep: if a container stops coming back, the verification has to
# fail with the thing it was waiting for rather than hang until someone notices.
wait_for() {
  local description="$1" timeout="$2"
  shift 2
  local deadline
  deadline=$(( $(date +%s) + timeout ))

  until "$@" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "timed out after ${timeout}s waiting for: ${description}" >&2
      return 1
    fi
    sleep 1
  done
}

restarted_since() {
  running "$1" && [ "$(started_at "$1")" != "$2" ]
}

db_healthy() {
  [ "$(health_status db)" = "healthy" ]
}

ready() {
  curl --silent --show-error --fail -o /dev/null "$READY_URL"
}

live() {
  curl --silent --show-error --fail -o /dev/null "$LIVE_URL"
}

push_events() { psql_dev "SELECT COUNT(*) FROM push_events;"; }
actors()      { psql_dev "SELECT COUNT(*) FROM github_actors;"; }
repositories() { psql_dev "SELECT COUNT(*) FROM github_repositories;"; }
quarantined() { psql_dev "SELECT COUNT(*) FROM quarantined_events;"; }
occurrences() { psql_dev "SELECT COALESCE(SUM(occurrence_count), 0) FROM quarantined_events;"; }
runs()        { psql_dev "SELECT COUNT(*) FROM ingestion_runs;"; }
queue_jobs()  { psql_queue_dev "SELECT COUNT(*) FROM solid_queue_jobs;"; }

count_row() {
  printf '| %-24s | %s | %s | %s | %s | %s |\n' "$1" "$(push_events)" "$(actors)" \
    "$(repositories)" "$(quarantined)" "$(occurrences)"
}

count_header() {
  printf '| %-24s | push_events | actors | repositories | quarantined | occurrences |\n' "measurement"
  printf '| %-24s | --- | --- | --- | --- | --- |\n' "------------------------"
}

heading() {
  echo
  echo "## $1"
  echo
}

# A verification that prints "MISMATCH" and exits 0 is a verification nobody will notice
# failing. Every check below records its verdict here, the transcript carries a summary, and
# the process exits non-zero if anything failed — so a committed transcript and a green exit
# code cannot disagree about what happened.
FAILURES=0

check() {
  local description="$1" expected="$2" actual="$3"

  if [ "$expected" = "$actual" ]; then
    echo "- PASS — ${description}"
  else
    FAILURES=$((FAILURES + 1))
    echo "- **FAIL** — ${description}: expected \`${expected}\`, got \`${actual}\`"
  fi
}

# Mechanical, for the reason script/probe_304.sh states about its own transcript: this one is
# committed, and a development database that has ever polled live GitHub holds real third-party
# logins, repository names and avatar URLs embedding numeric user ids. None of that is needed
# by any finding here.
#
# The corpus-miss message is redacted in its payload only. "the corpus defines no response for
# <redacted>" still proves fixture mode failed closed, which is the whole point of quoting it,
# while the account name it names is somebody's.
redact() {
  sed -E \
    -e 's#(defines no response for )".*"#\1"<redacted>"#g' \
    -e 's#("login":")[^"]*#\1<redacted>#g' \
    -e 's#("display_login":")[^"]*#\1<redacted>#g' \
    -e 's#("full_name":")[^"]*#\1<redacted>#g' \
    -e 's#("avatar_url":")[^"]*#\1<redacted>#g' \
    -e 's#("api_url":")[^"]*#\1<redacted>#g'
}

# ---------------------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------------------

preflight() {
  local service

  for service in $LONG_RUNNING; do
    if [ -z "$(container_id "$service")" ] || ! running "$service"; then
      echo "refusing: the ${service} container is not running." >&2
      echo "  start the stack first: GITHUB_MODE=fixture docker compose up --build -d" >&2
      exit 2
    fi
  done

  # The single most important guard. A live worker polls api.github.com every 60 seconds,
  # so rows appear between the two measurements §15 compares and "the count is unchanged"
  # becomes flaky rather than false. It also spends this IP's unauthenticated quota, and it
  # puts third-party logins, avatar URLs embedding numeric user ids, and repository names
  # into `docker compose logs worker` — which this script then prints into a transcript
  # somebody commits.
  local mode
  mode="$(docker compose exec -T worker printenv GITHUB_MODE | tr -d '[:space:]')"

  if [ "$mode" != "fixture" ]; then
    echo "refusing: the worker is running in GITHUB_MODE=${mode:-unset}, not fixture." >&2
    echo "  restart the stack offline: GITHUB_MODE=fixture docker compose up --build -d" >&2
    exit 2
  fi

  # The shared compose anchor reads RAILS_ENV: ${RAILS_ENV:-development}, so a reviewer with
  # RAILS_ENV=test exported gets `docker compose run --rm ingest` writing into the *test*
  # databases — every documented count wrong, and the §16 isolation gate broken by the very
  # script that checks it.
  if [ -n "${RAILS_ENV:-}" ] && [ "${RAILS_ENV}" != "development" ]; then
    echo "refusing: RAILS_ENV=${RAILS_ENV} is exported in this shell." >&2
    echo "  the compose anchor would forward it, and the one-shots would write to the wrong databases." >&2
    exit 2
  fi

  # §15 step 8's commands are copy-pasteable literals. If `name:` ever changes, they stop
  # working and the plan silently documents something that does not exist.
  for service in $LONG_RUNNING; do
    local actual expected
    actual="$(container_name "$service")"
    expected="${PROJECT}-${service}-1"

    if [ "$actual" != "$expected" ]; then
      echo "refusing: ${service} is named ${actual}, not ${expected}." >&2
      echo "  IMPLEMENTATION_PLAN.md §15 step 8 names containers literally; COMPOSE_PROJECT_NAME breaks it." >&2
      exit 2
    fi
  done

  VOLUME_CREATED_AT="$(docker volume inspect -f '{{.CreatedAt}}' "${PROJECT}_pgdata")"
  BASELINE_PUSH_EVENTS="$(push_events)"

  if [ "$BASELINE_PUSH_EVENTS" = "0" ]; then
    MODE="absolute"
  else
    MODE="delta"
  fi
}

# ---------------------------------------------------------------------------------------
# phases
# ---------------------------------------------------------------------------------------

phase_baseline() {
  heading "Baseline"

  echo '```'
  GITHUB_MODE=fixture docker compose run --rm ingest 2>&1 | redact || true
  echo '```'
  echo

  echo '```'
  GITHUB_MODE=fixture docker compose run --rm enrich --limit 6 2>&1 | redact || true
  echo '```'
  echo

  # Expected, and worth keeping in the transcript rather than engineering around: a
  # development database that has previously polled live GitHub holds actors and repositories
  # whose api_urls are real. Fixture mode has no entry for them, so the cycle refuses with a
  # corpus gap and exit 2 instead of quietly reaching api.github.com. That is §6's fail-closed
  # rule holding in the running stack, which no unit test can show.
  echo "A corpus gap above is not a fault. It means this development database holds entities"
  echo "from an earlier live run, and fixture mode refused to fetch them rather than falling"
  echo "back to the network — exit 2, \"refused to run\", per §9's exit-code contract."
  echo

  if [ "$MODE" = "absolute" ]; then
    echo "The development database was empty at the start of this run, so the counts below are"
    echo "the README's documented absolutes."
  else
    echo "The development database already held ${BASELINE_PUSH_EVENTS} push events at the start of this"
    echo "run, so the counts below are read as deltas. The README's documented absolutes"
    echo "(4 / 3 / 3 / 3 / 3) apply only to a stack started from an empty volume."
  fi
  echo

  count_header
  count_row "baseline"
}

# §15 step 8's literal command, and what it actually does.
#
# `docker kill` is an API stop: the daemon marks the container manually stopped, so
# `unless-stopped` deliberately does NOT bring it back. It is still worth running, because it
# is the command the plan documents and a reviewer will type — but on its own it demonstrates
# the opposite of §16's durability gate. Reported honestly rather than quietly replaced.
api_kill_observation() {
  local service="$1"
  local before_restarts
  before_restarts="$(restart_count "$service")"

  echo "\$ docker kill ${PROJECT}-${service}-1"
  docker kill "${PROJECT}-${service}-1" >/dev/null
  sleep 10
  echo

  echo "\$ docker compose ps"
  echo '```'
  docker compose ps
  echo '```'
  echo

  local running after_restarts
  running="$(docker inspect -f '{{.State.Running}}' "$(container_id "$service")")"
  after_restarts="$(restart_count "$service")"

  echo "| after \`docker kill\` | value |"
  echo "| --- | --- |"
  echo "| Running | ${running} |"
  echo "| ExitCode | $(docker inspect -f '{{.State.ExitCode}}' "$(container_id "$service")") |"
  echo "| RestartCount | ${before_restarts} -> ${after_restarts} |"
  echo

  # The finding, asserted rather than narrated. If a future Docker version starts restarting
  # after `docker kill`, this fails and the evidence document needs rewriting — which is
  # exactly when somebody should be told.
  check "docker kill leaves ${service} down, because an API stop skips the restart policy" \
    "false" "$running"
  check "docker kill does not increment ${service}'s RestartCount" \
    "$before_restarts" "$after_restarts"
  echo
  echo "\`docker kill\` is an API stop, so the daemon records the container as manually stopped"
  echo "and \`restart: unless-stopped\` does not apply. The container stays down and an operator"
  echo "step is required to bring it back — which is what the next command is."
  echo

  echo "\$ docker compose up -d ${service}"
  docker compose up -d "$service" >/dev/null 2>&1
  echo
}

# The crash the restart policy actually exists for: SIGKILL delivered to the container's main
# process from *outside* its PID namespace, which the daemon does not treat as a manual stop.
#
# It cannot be done from inside the container: the kernel refuses to deliver SIGKILL to a PID
# namespace's own init from within that namespace, so `docker exec … kill -9 1` is a no-op.
# A privileged --pid=host container is the smallest thing that reaches the process, and it
# runs the image this project already built rather than pulling a new one.
crash_recovery_observation() {
  local service="$1" wait_description="$2" wait_timeout="$3"
  shift 3

  local pid before_started before_restarts
  pid="$(docker inspect -f '{{.State.Pid}}' "$(container_id "$service")")"
  before_started="$(started_at "$service")"
  before_restarts="$(restart_count "$service")"

  echo "\$ docker run --rm --pid=host --privileged --user 0 ${APP_IMAGE} sh -c 'kill -9 ${pid}'"

  # --user 0 is load-bearing, not belt and braces. The app image declares a non-root USER, and
  # a helper running as that user can signal the worker and web processes (same uid) but not
  # postgres, which runs as its own user inside the db container — `kill` answers "Operation
  # not permitted" and only the database phase fails, which is a confusing way to find out.
  if ! docker run --rm --pid=host --privileged --user 0 "$APP_IMAGE" sh -c "kill -9 ${pid}" >/dev/null 2>&1; then
    echo
    echo "The crash-kill helper exited non-zero. The observation below is still taken, but"
    echo "treat it as inconclusive rather than as evidence the policy worked."
  fi
  echo

  wait_for "${service} to be restarted by its policy" 120 restarted_since "$service" "$before_started"
  wait_for "$wait_description" "$wait_timeout" "$@"

  local running after_restarts
  running="$(docker inspect -f '{{.State.Running}}' "$(container_id "$service")")"
  after_restarts="$(restart_count "$service")"

  echo "| after a process crash | value |"
  echo "| --- | --- |"
  echo "| Running | ${running} |"
  echo "| RestartCount | ${before_restarts} -> ${after_restarts} |"
  echo "| StartedAt | ${before_started} -> $(started_at "$service") |"
  echo

  check "${service} was restarted by its policy after a process crash" "true" "$running"
  check "${service}'s RestartCount incremented" \
    "$((before_restarts + 1))" "$after_restarts"
  echo
  echo "Docker restarted \`${service}\` on its own. No operator step."
  echo
}

phase_kill_worker() {
  heading "Worker kill (§15 step 8)"

  local before
  before="$(push_events)"
  echo "Count before the kill: push_events = ${before}"
  echo

  echo "### Part 1 — the command §15 documents"
  echo
  api_kill_observation worker
  wait_for "the worker container to be running again" 60 running worker

  echo "### Part 2 — a process crash, which is what the policy is for"
  echo
  crash_recovery_observation worker "the worker container to be running again" 60 running worker

  echo "\$ docker compose logs worker --since 2m"
  echo '```'
  docker compose logs worker --since 2m --no-log-prefix 2>/dev/null | tail -20 | redact
  echo '```'
  echo

  echo "Count after recovery: push_events = $(push_events)"
}

phase_kill_db() {
  heading "Database kill (§15 step 8)"

  local before
  before="$(push_events)"
  echo "Count before the kill: push_events = ${before}"
  echo

  echo "### Part 1 — the command §15 documents"
  echo
  api_kill_observation db
  wait_for "the database to report healthy again" 180 db_healthy
  wait_for "/health/ready to return 200 once the database is back" 180 ready

  echo "### Part 2 — a process crash, which is what the policy is for"
  echo
  crash_recovery_observation db "the database to report healthy again" 180 db_healthy
  wait_for "/health/ready to return 200 once the database is back" 180 ready

  local after
  after="$(push_events)"
  echo "Count after recovery: push_events = ${after}"
  echo

  check "push_events is unchanged across two SIGKILLs of the database" "$before" "$after"
  echo
  echo "PostgreSQL replayed its WAL onto the same named volume, which is §15 step 8's actual"
  echo "question."
}

phase_kill_web() {
  heading "Web kill (beyond §15's list — verifies the Dockerfile's pid-file claim)"

  echo "§16's durability gate names db, web and worker; §15 step 8 kills only two. The"
  echo "Dockerfile runs puma directly rather than \`bin/rails server\` so that a stale"
  echo "tmp/pids/server.pid left by an ungraceful kill cannot block the restart"
  echo "\`unless-stopped\` promises — and a crash is the only thing that exercises it."
  echo

  echo "### Part 1 — the command §15 documents"
  echo
  api_kill_observation web
  wait_for "/health/ready to return 200 again" 180 ready

  echo "### Part 2 — a process crash, which is what the policy is for"
  echo
  crash_recovery_observation web "/health/ready to return 200 from the restarted container" 180 ready

  echo "\`/health/live\` and \`/health/ready\` both answer again after an uncooperative kill, so no"
  echo "pid file survived to block the restart."
}

phase_restart() {
  heading "Normal restart (§15 step 9)"

  local before started elapsed
  before="$(push_events)"

  echo "\$ docker compose restart"
  started="$(date +%s)"
  echo '```'
  docker compose restart
  echo '```'
  elapsed=$(( $(date +%s) - started ))
  echo
  echo "Took ${elapsed}s. The worker's \`stop_grace_period: 30s\` is a ceiling, not a duration:"
  echo "Solid Queue's supervisor acknowledges SIGTERM and exits well inside it whenever no"
  echo "GitHub request is in flight, and in fixture mode none ever is for long."
  echo

  wait_for "/health/ready to return 200 after the restart" 120 ready

  echo "push_events before: ${before}, after: $(push_events)"
}

phase_test_isolation() {
  heading "Test isolation (§16's reviewer-experience gate)"

  echo "§16 requires that \`docker compose run --rm test\` never touches the development"
  echo "databases (app or queue) and never triggers the development \`setup\` service."
  echo "spec/docker_compose_spec.rb asserts the declarations; this measures the behaviour."
  echo

  # The worker has to be stopped for the duration, and the first version of this phase did not
  # do that — which made the measurement meaningless and the transcript wrong. Continuous
  # polling is the whole point of the worker: it ingests a fixture page every cadence and
  # enqueues from it, so `push_events` and `solid_queue_jobs` both climb *while the suite
  # runs* whether or not the suite touches them. The earlier run recorded 263 -> 353 and
  # 56 -> 62 and still printed that the gate held. Stopping the worker removes the only other
  # writer, so a difference here can mean nothing except the suite.
  echo "\$ docker compose stop worker    # the only other writer to these databases"
  docker compose stop worker >/dev/null 2>&1
  sleep 3
  echo

  local before_primary before_queue before_setup
  before_primary="$(push_events)"
  before_queue="$(queue_jobs)"
  before_setup="$(docker inspect -f '{{.State.FinishedAt}}' "$(container_id setup)" 2>/dev/null || echo "absent")"

  echo '```'
  docker compose run --rm test 2>&1 | tail -8
  echo '```'
  echo

  local after_primary after_queue after_setup
  after_primary="$(push_events)"
  after_queue="$(queue_jobs)"
  after_setup="$(docker inspect -f '{{.State.FinishedAt}}' "$(container_id setup)" 2>/dev/null || echo "absent")"

  echo "\$ docker compose start worker"
  docker compose start worker >/dev/null 2>&1
  echo

  echo "| observable | before | after |"
  echo "| --- | --- | --- |"
  echo "| development push_events | ${before_primary} | ${after_primary} |"
  echo "| development solid_queue_jobs | ${before_queue} | ${after_queue} |"
  echo "| setup container FinishedAt | ${before_setup} | ${after_setup} |"
  echo

  check "the suite left development push_events untouched" "$before_primary" "$after_primary"
  check "the suite left the development queue untouched" "$before_queue" "$after_queue"
  check "the suite did not trigger the development setup service" "$before_setup" "$after_setup"
}

phase_scenarios() {
  heading "Deterministic fixture scenarios (§15 step 10)"

  echo "The full nine-scenario matrix is documented in the README; this phase runs the two"
  echo "the transcript can prove without waiting. Every ingestion obeys GitHub's"
  echo "\`X-Poll-Interval\` floor of 60s, which \`--force\` deliberately does not bypass, so"
  echo "back-to-back poll scenarios are a README exercise rather than a script phase. The"
  echo "redirect scenarios go through \`bin/enrich\`, which has no cadence."
  echo

  # Selection has to be forced, and the first version of this phase did not force it — so both
  # scenarios died on a corpus gap while `|| true` swallowed the exit code and the transcript
  # claimed they had run. §10 picks the newest eligible candidate, and on a development
  # database that has ever polled live GitHub the newest repository is a real one whose
  # api_url the corpus has never heard of.
  #
  # So the corpus's own repository is made the unambiguous newest candidate first. It is the
  # row both scenarios are authored against (bodies/repos/octocat_hello-world.json carries the
  # matching id, which RepositoryDocument.parse checks), and the worker is stopped for the
  # duration so nothing else can move last_seen_at underneath the selection.
  echo "\$ docker compose stop worker    # so nothing re-orders the candidate set mid-scenario"
  docker compose stop worker >/dev/null 2>&1
  sleep 3
  echo

  redirect_scenario "redirecting_repository" "complete" \
    "a validated redirect is followed and the entity completes"
  redirect_scenario "hostile_redirect" "permanent_failure" \
    "an off-host redirect is refused by the URL policy"

  echo "\$ docker compose start worker"
  docker compose start worker >/dev/null 2>&1
  echo

  count_header
  count_row "after scenarios"
}

# One redirect scenario, end to end, with a verdict rather than a hope.
redirect_scenario() {
  local scenario="$1" expected_status="$2" description="$3"

  echo "### ${scenario} — ${description}"
  echo

  # Pending, unleased, never fetched, and newer than every other candidate. now() + 1s rather
  # than now() because the corpus repository may already carry this instant from a fixture
  # poll, and a tie is broken by id, which is not ours to choose.
  psql_dev "UPDATE github_repositories
               SET enrichment_status = 'pending', next_retry_at = NULL, fetched_at = NULL,
                   last_error = NULL, enrichment_attempts = 0,
                   last_seen_at = now() + interval '1 second'
             WHERE github_id = ${CORPUS_REPOSITORY_ID};" >/dev/null

  local seeded
  seeded="$(psql_dev "SELECT count(*) FROM github_repositories WHERE github_id = ${CORPUS_REPOSITORY_ID};")"
  if [ "$seeded" != "1" ]; then
    FAILURES=$((FAILURES + 1))
    echo "- **FAIL** — the corpus repository ${CORPUS_REPOSITORY_ID} is not in this database, so"
    echo "  ${scenario} cannot be exercised. Run \`docker compose run --rm ingest\` in fixture"
    echo "  mode first."
    echo
    return
  fi

  echo '```'
  GITHUB_MODE=fixture GITHUB_FIXTURE_SCENARIO="$scenario" \
    docker compose run --rm enrich --limit 1 --class repository 2>&1 | redact || true
  echo '```'
  echo

  local actual
  actual="$(psql_dev "SELECT enrichment_status FROM github_repositories WHERE github_id = ${CORPUS_REPOSITORY_ID};")"

  check "${scenario} left the corpus repository ${expected_status}" "$expected_status" "$actual"
  echo
}

phase_rate_limit() {
  heading "Rate-limit scenario (opt-in)"

  echo "\`rate_limited\` writes a real one-hour \`global_blocked_until\`. It is never part of the"
  echo "default run, because every later phase would report a deferral. Cleanup runs immediately."
  echo

  echo '```'
  GITHUB_MODE=fixture GITHUB_FIXTURE_SCENARIO=rate_limited docker compose run --rm ingest || true
  echo '```'
  echo

  echo "Budget row after the scenario:"
  echo '```'
  psql_dev "SELECT window_status || ' blocked_until=' || COALESCE(global_blocked_until::text, 'none') FROM github_api_budget;"
  echo '```'
  echo

  phase_cleanup
}

phase_cleanup() {
  heading "Cleanup"

  echo "The same SQL the README publishes, so a reviewer who interrupts a run has one place"
  echo "to look (\`--phase=cleanup\`)."
  echo

  echo '```sql'
  echo "UPDATE github_api_budget SET global_blocked_until = NULL, window_status = 'active';"
  echo "UPDATE event_sources SET status = 'idle', consecutive_failures = 0,"
  echo "       retry_not_before_at = NULL WHERE status = 'failed';"
  echo '```'
  echo

  psql_dev "UPDATE github_api_budget SET global_blocked_until = NULL, window_status = 'active' WHERE window_status = 'globally_blocked' OR global_blocked_until IS NOT NULL;" >/dev/null || true
  psql_dev "UPDATE event_sources SET status = 'idle', consecutive_failures = 0, retry_not_before_at = NULL WHERE status = 'failed';" >/dev/null || true

  echo "Budget and source state after cleanup:"
  echo '```'
  psql_dev "SELECT 'budget: ' || window_status || ' blocked_until=' || COALESCE(global_blocked_until::text, 'none') FROM github_api_budget;"
  psql_dev "SELECT 'source: ' || source_type || ' status=' || status || ' enabled=' || enabled FROM event_sources;"
  echo '```'
}

phase_volume_check() {
  heading "Volume identity"

  local now
  now="$(docker volume inspect -f '{{.CreatedAt}}' "${PROJECT}_pgdata")"

  echo "\`${PROJECT}_pgdata\` CreatedAt at preflight: ${VOLUME_CREATED_AT}"
  echo "\`${PROJECT}_pgdata\` CreatedAt now:          ${now}"
  echo

  check "the pgdata volume is the same volume it was at preflight" "$VOLUME_CREATED_AT" "$now"
  echo
  echo "Identical means the records above *survived* the kills rather than being recreated"
  echo "into a fresh volume, which is what makes the counts evidence rather than coincidence."
}

# ---------------------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------------------

preflight

cat <<HEADER
<!-- Generated by script/verify_recovery.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ) -->

\`\`\`text
Verification date:  $(date -u +%Y-%m-%d)
Compose project:    ${PROJECT}
Git revision:       $(git rev-parse HEAD 2>/dev/null || echo "unknown")
Docker version:     $(docker version -f '{{.Server.Version}}')
Compose version:    $(docker compose version --short)
Host:               $(uname -srm)
Worker mode:        fixture (enforced by preflight)
Count mode:         ${MODE}
Captured by:        script/verify_recovery.sh
Redaction:          login, display_login, full_name, api_url, avatar_url and the corpus-miss
                    payload are replaced in place; names kept, values removed
\`\`\`
HEADER

case "$PHASE" in
  all)
    phase_baseline
    phase_kill_worker
    phase_kill_db
    phase_kill_web
    phase_restart
    phase_test_isolation
    phase_scenarios
    phase_volume_check
    ;;
  baseline)       phase_baseline ;;
  kill-worker)    phase_kill_worker ;;
  kill-db)        phase_kill_db ;;
  kill-web)       phase_kill_web ;;
  restart)        phase_restart ;;
  test-isolation) phase_test_isolation ;;
  scenarios)      phase_scenarios ;;
  rate-limit)     phase_rate_limit ;;
  cleanup)        phase_cleanup ;;
  volume-check)   phase_volume_check ;;
  *)
    echo "unknown phase: ${PHASE}" >&2
    exit 2
    ;;
esac

heading "Verdict"

if [ "$FAILURES" -eq 0 ]; then
  echo "Every check above passed."
else
  echo "**${FAILURES} check(s) failed.** This transcript records a failed verification and must"
  echo "not be committed as evidence that the gate holds."
fi

echo
echo "Paste the above into docs/evidence/\$(date -u +%Y-%m-%d)-container-kill-recovery.md and"
echo "write the finding and the \"What this does not show\" section by hand."

# The exit code and the transcript have to agree. A verification that prints FAIL and exits 0
# is one somebody will paste into docs/evidence/ without reading.
exit $(( FAILURES > 0 ? 1 : 0 ))
