# Clean-checkout verification

Date: 2026-07-31

Status: Historical first-party observation; enrichment policy superseded

> [!IMPORTANT]
> This transcript verifies revision `6eab84c` and preserves its then-current
> `skipped_budget`/`enrichment.reactivated` assertions as historical evidence. They are not
> current acceptance gates. The 2026-08-02 durable-backlog correction removes that terminal
> state, restores affected rows, and makes quota exhaustion a deferral; see
> [`IMPLEMENTATION_PLAN.md` Appendix F](../../IMPLEMENTATION_PLAN.md) and
> [ADR 0007](../adr/0007-enrichment-fairness-shares-and-borrowing.md).

Revision verified: `6eab84c6ce6b0660cc124b7b2d1c4012fc127222`
(branch `issue-22-reviewer-documentation`; the post-merge run against the default branch is
a separate, later step; see [`docs/SUBMISSION_CHECKLIST.md`](../SUBMISSION_CHECKLIST.md) §1)

```text
Docker version:   28.3.0
Compose version:  v2.38.1-desktop.1
Image store:      containerd (io.containerd.snapshotter.v1)
Compose Bake:     enabled (Docker Desktop default; COMPOSE_BAKE unset)
Host:             Darwin 25.5.0 arm64
Clone:            git clone https://github.com/batbrainy/github-push-ingestor.git
                  into an empty directory, no .env, no config/master.key
Volume:           github-push-ingestor_pgdata created fresh at 2026-07-31T16:29:55Z
```

## Why this verification exists

`IMPLEMENTATION_PLAN.md` §13 makes clean-checkout verification a PR 12 deliverable and §16
makes "clean checkout works" a gate, but nothing in CI or the suite can prove it.
`spec/docker_compose_spec.rb` asserts what the YAML *declares*; only a real run shows four
containers actually starting. And only a clone into an empty directory, on a host with no
image, proves the "no secrets, no local toolchain" claim: a working tree can pass gates a
clone would fail, on an untracked `.env`, a `config/master.key`, or a warm image.

That last difference is not hypothetical here. It is what this verification caught.

## The finding

`docker compose up --build`, the assignment's first command, failed from a cold image
and started zero containers.

```text
target worker: failed to solve:
image "docker.io/library/github-push-ingestor-app:latest": already exists
```

```text
$ docker compose ps -a
NAME      IMAGE     COMMAND   SERVICE   CREATED   STATUS    PORTS
(empty)
```

Compose Bake, enabled by default in Docker Desktop, makes every service declaring a
`build:` its own bake target. Six services declared `build: .` against the same
`image: github-push-ingestor-app`, so the targets raced to export one tag and the losers
aborted the whole `up`.

It reproduces only when the image is absent, which is a reviewer's first command and
no other run. Every prior run in this project's history happened on a machine where the
image already existed, which is why a spec-guarded, deliberate design property had been
silently broken for a reviewer the entire time.

Fixed in `6eab84c`: `setup` is now the only service on the `up` path that builds; `web` and
`worker` reference the tag and already wait on `setup: service_completed_successfully`.
The `tools` one-shots keep their own build (each is invoked alone by `docker compose run`,
a single target that cannot collide) plus `pull_policy: build`, so Compose stops
attempting a registry pull of a tag that is local-only by construction.
`spec/docker_compose_spec.rb` now asserts that invariant.

Everything below was then verified against the fixed revision.

## What else was measured

No host toolchain is used. This host does have a Ruby, and it is the wrong one, which
makes the point better than an absent one would:

```text
$ ruby --version
ruby 4.0.5 (2026-05-20 revision 64336ffd0e) +PRISM [arm64-darwin25]
$ cat .ruby-version
ruby-3.4.10
$ bundle check
The following gems are missing
 * rails (8.1.3.1)
 * pg (1.6.3)
$ which psql
psql not found
```

The host cannot run this project. It ran anyway, because Ruby 3.4.10 and every gem live in
the image. Cold build: 992 MB, `BUNDLE_FROZEN=1` against the committed `Gemfile.lock`.

Startup order, from an empty volume, exactly as the README documents:

```text
db → healthy → setup → Exited (0) → web + worker

db      Up 7 seconds (healthy)
setup   Exited (0)
web     Up (health: starting)
worker  Up
```

Four services. No others: `ingest`, `enrich` and `test` sit behind the `tools` profile.

Health endpoints answered immediately: `/health/live` and `/health/ready` both
`{"status":"ok"}`.

### The live half: §16's first functional gate

One unauthenticated poll against the real API, from a clone with no token and no `.env`:

```text
{"event":"budget.window_initialized","limit":60,"reserve":8,"poll_allowance":12,
 "enrichment_allowance":40,"actor_guarantee":20,"repository_guarantee":20,
 "rate_limit_resource":"core","rate_limit_limit":60,"rate_limit_remaining":59,
 "rate_limit_used":1,"rate_limit_reset_at":"2026-07-31T17:24:00Z","poll_used":1}

{"event":"ingestion.run_completed","run_id":"0b6d7cf1-5210-42ff-9d25-34a985585e3c",
 "duration_ms":1057.1,"run_status":"completed","stop_reason":"page_cap","pages_fetched":1,
 "events_received":100,"push_events_seen":96,"events_created":96,"duplicates_skipped":0,
 "events_quarantined":0,"events_ignored":4,"events_failed":0}

{"event":"enrichment.completed","entity_type":"repository","github_id":937042218,
 "pool":"pending","classification":"ok","entity_status":"complete","enrichment_attempt":1}
{"event":"enrichment.completed","entity_type":"actor","github_id":148442705,
 "pool":"pending","classification":"ok","entity_status":"complete","enrichment_attempt":1}
```

96 push events persisted from one page of 100, four non-push events ignored and counted,
and both entity classes enriched. The ledger bootstrapped from GitHub's own headers
rather than a discovery request. Total spend for the live half: 3 requests of 60; the
window was back to `60/60` by the end of the session.

Third-party identifiers above are numeric GitHub ids only. Logins, display logins, full
names, API URLs and avatar URLs are redacted from this transcript under the same rule
`script/verify_recovery.sh` applies: names kept, values removed.

### The fixture half: the documented absolutes

From an empty volume, `GITHUB_MODE=fixture`:

```text
 push_events | actors | repositories | quarantined | occurrences
           4 |      3 |            3 |           3 |           3
```

Exactly the numbers the README documents. After `enrich --limit 6`:

```text
   class    | enrichment_status | count
 actor      | complete          |     2
 actor      | permanent_failure |     1
 repository | complete          |     2
 repository | permanent_failure |     1
```

The two `permanent_failure` rows are the corpus's deliberate `404` on event
`58000000008`: a dead enrichment target must fail the *entity* and leave the source
running.

Replay, past the 60-second `X-Poll-Interval` floor (§15 step 7):

```text
Push events created:              0
Duplicates skipped:               4
Events quarantined:               3

 push_events | occurrences | skipped
           4 |           6 |       0
```

Four duplicates absorbed, occurrence counts 3 → 6, `push_events` unchanged, and
`grep enrichment.reactivated` over the whole log returned nothing, with the
`skipped_budget` count still 0. Both halves of §15 step 7, not just the countable one.

### Crash recovery (§15 steps 8 to 10)

`script/verify_recovery.sh --confirm` on the empty-volume stack: 19 checks, all passed,
and for the first time in `Count mode: absolute` rather than delta. The committed
transcript at
[`2026-07-31-container-kill-recovery.md`](2026-07-31-container-kill-recovery.md) had to run
against a populated database and says so. The `pgdata` volume's `CreatedAt` was identical
before and after, so the surviving records survived the kills rather than being recreated.

### Tests (§15 step 11)

```text
1728 examples, 0 failures      # the suite
  10 examples, 0 failures      # spec/stress
```

Repeated with `--seed 4242` on both invocations: identical, `0 failures`.

Test isolation, measured rather than asserted. The poller was stopped first so the
counts could not move on their own:

```text
BEFORE  dev push_events=94  queue jobs=10
AFTER   dev push_events=94  queue jobs=10
PASS — the test run touched neither development database
setup  Exited (0)      # not re-triggered by the test service
```

## What this does not show

- One host, one date, one Docker version. The Bake collision is specific to Compose
  Bake plus the containerd image store; a host with Bake disabled would never have seen it,
  which is exactly why it survived so long.
- The live half is one poll from one IP whose 60-request budget is shared with any
  co-tenant behind the same address. It shows the API is reachable without a token. It
  shows nothing about sustained behaviour, and nothing about authenticated requests: this
  project has no token and cannot test that case.
- The fixture counts are properties of the committed corpus, not of GitHub. They prove
  the pipeline is deterministic; they prove nothing about what the live feed contains.
- Nothing here proves complete upstream capture. 96 push events from one page is one
  sample of a sliding window with 30-second-to-6-hour latency. The system does not claim to
  mirror the feed.
- `verify_recovery.sh`'s own stated limit still applies: the documented `docker kill` is an
  API stop that `restart: unless-stopped` is defined to skip. The script kills twice and
  reports both.
- The stack ends in live mode. Bringing a killed container back means
  `docker compose up -d <service>`, which recreates it from the current shell environment,
  where `GITHUB_MODE` defaults to `live`. Observed here and now documented in the README's
  crash-recovery section.

## Every check in this run

1. Clone into an empty directory; `git status --porcelain` empty. PASS
2. No `.env`, no `config/master.key` in the clone. PASS
3. Host Ruby is 4.0.5 against a 3.4.10 pin, gems absent, no `psql`. PASS
4. Cold `docker compose build --no-cache --pull`, `BUNDLE_FROZEN=1`, 992 MB. PASS
5. Cold `docker compose up --build` starts exactly `db`, `setup`, `web`, `worker`. PASS *(after `6eab84c`; FAILED before it, see the finding)*
6. `/health/live` and `/health/ready` both `{"status":"ok"}`. PASS
7. Live: one unauthenticated poll persisted 96 push events, 4 ignored. PASS
8. Live: ledger bootstrapped from response headers, 60/57. PASS
9. Live: both actor and repository enrichment completed. PASS
10. Fixture: 4 / 3 / 3 / 3 / 3 from an empty volume. PASS
11. Fixture: `complete 2 / permanent_failure 1` per class. PASS
12. Replay: 4 duplicates absorbed, occurrences 3 → 6, `push_events` unchanged. PASS
13. Replay: no `enrichment.reactivated`, `skipped_budget` still 0. PASS
14. `script/verify_recovery.sh --confirm`: 19 checks, absolute count mode. PASS
15. `pgdata` volume identity unchanged across the kills. PASS
16. Suite 1728 + 10, `0 failures`. PASS
17. Fixed-seed repeat identical. PASS
18. Test run changed neither development database; `setup` not re-triggered. PASS

## Reproducing it

```bash
# from a host with no image for this project
docker compose down -v --remove-orphans          # if a stack exists
docker image rm github-push-ingestor-app

git clone https://github.com/batbrainy/github-push-ingestor.git /tmp/ghpi && cd /tmp/ghpi
git status --porcelain                            # must be empty
test ! -e .env && test ! -e config/master.key

docker compose build --no-cache --pull            # the cold path
docker compose up --build -d                      # live; the assignment's command
until curl -fsS http://localhost:3000/health/ready; do sleep 2; done
curl -s http://localhost:3000/status | jq .ledger
docker compose down -v

GITHUB_MODE=fixture docker compose up --build -d  # the deterministic half
script/verify_recovery.sh --confirm               # §15 steps 8-10
docker compose run --rm test                      # §15 step 11
docker compose down -v --remove-orphans
```

Allow roughly an hour, including three mandatory 60-second `X-Poll-Interval` waits between
successive ingestion scenarios.
