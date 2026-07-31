# Submission checklist

Repository: https://github.com/batbrainy/github-push-ingestor

This is a reusable runbook, not a record of one run. Keep the boxes unchecked in the
repository. The external findings report records the default-branch SHA, UTC date, command,
exit code, salient output, duration, and one classification for every gate: pass, repository
defect, environment issue, or documentation mismatch.

Run every gate against the default branch after the final hardening change merges, from a
fresh clone — never against a working tree. A working tree can hide an untracked `.env` or
`config/master.key`, while Compose's fixed project name can make even a fresh clone reuse a
stale image or the globally named `github-push-ingestor_pgdata` volume.

---

## 1. Authoritative clean-checkout verification

### Fresh clone and cold-image live startup

- [ ] Clone into a newly created parent directory, record the full SHA externally, and prove
      the clone is clean:

      ```bash
      verification_parent="$(mktemp -d)"
      git clone https://github.com/batbrainy/github-push-ingestor.git \
        "$verification_parent/repository"
      cd "$verification_parent/repository"
      git rev-parse HEAD
      test -z "$(git status --porcelain)"
      test ! -e .env
      test ! -e config/master.key
      ```

- [ ] Before destructive Docker commands, archive any valued data already stored in
      `github-push-ingestor_pgdata`. Because the project name is fixed, another clone can own
      that same volume.
- [ ] Remove prior project resources and the global volume, then require volume inspection to
      fail. Continuing past this point asserts the prior data is archived or disposable:

      ```bash
      docker compose down -v --remove-orphans
      if docker volume inspect github-push-ingestor_pgdata >/dev/null 2>&1; then
        echo "github-push-ingestor_pgdata still exists" >&2
        exit 1
      fi
      ```

- [ ] Exercise both cold build paths. Remove only the application image while no project
      containers exist:

      ```bash
      docker compose build --no-cache --pull
      docker image rm github-push-ingestor-app:latest
      docker compose up --build -d
      docker compose ps --all
      ```

- [ ] Exactly `db` healthy, `setup` exited 0, `web` healthy, and `worker` running; no
      tool-profile service started.
- [ ] `curl -fsS http://localhost:3000/health/ready` returns `{"status":"ok"}`.
- [ ] The live worker reaches the public GitHub Events API without a token. Record the
      corresponding worker log and budget change; do not infer this from a health endpoint.

### Empty-volume fixture phase

- [ ] End the live phase with an explicit destructive boundary, prove the global volume is
      absent, then start only `db`, `setup`, and `web` offline so the worker cannot race the
      one-shots:

      ```bash
      docker compose down -v --remove-orphans
      if docker volume inspect github-push-ingestor_pgdata >/dev/null 2>&1; then
        echo "github-push-ingestor_pgdata still exists" >&2
        exit 1
      fi
      GITHUB_MODE=fixture docker compose up --build -d db setup web
      curl -fsS http://localhost:3000/health/ready
      ```

- [ ] Capture fixture ingestion output directly. The `run --rm` container is removed, so no
      retained service log can validate it later:

      ```bash
      set -o pipefail
      fixture_ingest_output="$(mktemp)"
      GITHUB_MODE=fixture docker compose run --rm ingest 2>&1 | tee "$fixture_ingest_output"
      grep -E 'Push events created:[[:space:]]+4' "$fixture_ingest_output"
      grep -E 'Events quarantined:[[:space:]]+3' "$fixture_ingest_output"
      grep -E 'Non-push events ignored:[[:space:]]+1' "$fixture_ingest_output"
      ```

- [ ] `GITHUB_MODE=fixture docker compose run --rm enrich --limit 6` exits 0 and leaves
      `complete 2 / permanent_failure 1` in each entity class.
- [ ] SQL state is exactly 4 events, 3 actors, 3 repositories, 3 quarantine rows, and 3 total
      quarantine occurrences:

      ```bash
      docker compose exec -T db psql -U postgres -d github_push_ingestor_development -c "
        SELECT (SELECT COUNT(*) FROM push_events)                     AS push_events,
               (SELECT COUNT(*) FROM github_actors)                   AS actors,
               (SELECT COUNT(*) FROM github_repositories)             AS repositories,
               (SELECT COUNT(*) FROM quarantined_events)              AS quarantined,
               (SELECT SUM(occurrence_count) FROM quarantined_events) AS occurrences;
        SELECT 'actor' AS class, enrichment_status, COUNT(*) FROM github_actors GROUP BY 2
        UNION ALL
        SELECT 'repository', enrichment_status, COUNT(*) FROM github_repositories GROUP BY 2;"
      ```

- [ ] After the 60-second poll floor, capture `ingest --force`; require 4 duplicates and no
      `enrichment.reactivated` line in that captured output:

      ```bash
      sleep 60
      fixture_replay_output="$(mktemp)"
      GITHUB_MODE=fixture docker compose run --rm ingest --force 2>&1 | tee "$fixture_replay_output"
      grep -E 'Duplicates skipped:[[:space:]]+4' "$fixture_replay_output"
      if grep -q 'enrichment.reactivated' "$fixture_replay_output"; then
        echo "duplicate replay reactivated an entity" >&2
        exit 1
      fi
      rm -f "$fixture_ingest_output" "$fixture_replay_output"
      ```

### Tests, recovery, and persistence

- [ ] Record development `push_events`, development `solid_queue_jobs`, and the setup
      container ID/finish time. Run the requested suite and two consecutive repeats, one with
      fixed seed 4242, then prove those three development observations are unchanged:

      ```bash
      docker compose exec -T db psql -U postgres \
        -d github_push_ingestor_development -Atc 'SELECT COUNT(*) FROM push_events;'
      docker compose exec -T db psql -U postgres \
        -d github_push_ingestor_queue_development -Atc 'SELECT COUNT(*) FROM solid_queue_jobs;'
      setup_container_id="$(docker compose ps --all --quiet setup)"
      docker inspect --format '{{.Id}} {{.State.FinishedAt}}' "$setup_container_id"

      docker compose run --rm --build test
      docker compose run --rm test
      docker compose run --rm test bash -c \
        'bin/rails db:test:prepare && bundle exec rspec --seed 4242 && bundle exec rspec spec/stress --seed 4242'

      docker compose exec -T db psql -U postgres \
        -d github_push_ingestor_development -Atc 'SELECT COUNT(*) FROM push_events;'
      docker compose exec -T db psql -U postgres \
        -d github_push_ingestor_queue_development -Atc 'SELECT COUNT(*) FROM solid_queue_jobs;'
      docker inspect --format '{{.Id}} {{.State.FinishedAt}}' "$setup_container_id"
      ```

- [ ] Reset to another empty volume, start the full stack offline, and run recovery. Every
      subprocess and assertion exits 0, and the worker is still offline afterward:

      ```bash
      docker compose down -v --remove-orphans
      GITHUB_MODE=fixture docker compose up --build -d
      GITHUB_MODE=fixture script/verify_recovery.sh --confirm
      test "$(docker compose exec -T worker printenv GITHUB_MODE)" = fixture
      ```

- [ ] `push_events` is equal before and after `docker compose restart`.
- [ ] `push_events` is equal before and after `docker compose down --remove-orphans` followed
      by `GITHUB_MODE=fixture docker compose up --build -d`.
- [ ] No local Ruby, PostgreSQL, or `psql` was used at any point.

The dated evidence files are historical inputs, not substitutes for this post-merge run. In
particular, read the erratum atop
[`2026-07-31-container-kill-recovery.md`](evidence/2026-07-31-container-kill-recovery.md).

---

## 2. Functional gates — §16

- [ ] Public GitHub Events API works without a token — *live half of the clean-checkout run*
- [ ] Only `PushEvent` records are processed — `Github::Events::ProcessorRegistry`; the
      corpus `WatchEvent` is ignored **and counted**
- [ ] Required fields are structured, typed, and `NOT NULL`; unknown payload fields
      tolerated; 40- and 64-char SHAs accepted — `spec/db/schema_spec.rb`,
      `spec/services/github/events/push_event_processor_spec.rb`
- [ ] Raw payload is retained (semantic retention, documented) —
      [ADR 0001](adr/0001-jsonb-semantic-retention.md), `GET /api/push_events/:id`
- [ ] **Both** actor and repository enrichment demonstrably occur within their fairness
      guarantees — `spec/services/github/enrichment/end_to_end_spec.rb`; fixture run gives
      `complete 2 / permanent_failure 1` per class
- [ ] A duplicate event ID cannot add another `push_events` row or reactivate a skipped entity
      — fixture replay: 4 duplicates absorbed, no `enrichment.reactivated`
- [ ] `Link`-header pagination is handled; every fetched page fully processed —
      `spec/services/github/ingestion/page_loop_spec.rb`; `paginated` scenario
- [ ] Rate-limit behavior demonstrated: `304` quota accounting, class-aware ledger
      enforcement, global-vs-class blocking, per-window bootstrap, scheduling rules —
      `docs/evidence/2026-07-30-unauthenticated-304-quota-probe.md`,
      `spec/stress/budget_ledger_spec.rb`
- [ ] Malformed data quarantined durably per the taxonomy (canonical fingerprints,
      occurrence-counted) and does not terminate the batch — 3 rows, occurrences 3 → 6 on
      replay, and 4 events persisted beside them

---

## 3. Durability gates — §16

- [ ] PostgreSQL uses a named volume — `docker-compose.yml`, `spec/docker_compose_spec.rb`
- [ ] Docker restart policies recover process crashes in `db`/`web`/`worker` automatically.
      `docker kill` is retained separately as an API-stop negative control and must leave an
      `unless-stopped` container down — `script/verify_recovery.sh`
- [ ] Application restart preserves events — runtime comparisons in §1
- [ ] Worker restart preserves pending work — `spec/recovery/worker_crash_lease_spec.rb`
- [ ] An event that did not commit before a crash can be observed again only if it remains in
      a later feed window; an event that did commit remains durable and its derived pending
      work is reconciled — `spec/recovery/crash_window_spec.rb`
- [ ] Advisory locks provably release on session death (tested) —
      `spec/recovery/advisory_lock_session_death_spec.rb`, real `pg_terminate_backend`
- [ ] The covered actor-job redelivery leaves an already-complete actor row unchanged —
      `spec/recovery/duplicate_job_execution_spec.rb`; this does not imply universal
      idempotency of persisted state
- [ ] Reconciliation recovers missing enrichment scheduling —
      `spec/recovery/pending_enrichment_recovery_spec.rb`
- [ ] The enrichment backlog is bounded (eligibility window + `skipped_budget` +
      distinct-event reactivation) — `spec/services/github/enrichment/age_out_spec.rb`

---

## 4. Operability gates — §16

- [ ] Logs readable through `docker compose logs -f` at the default level —
      README [Logs](../README.md#logs)
- [ ] Correlation fields (`run_id`, job ID) present — `app/jobs/application_job.rb`; the
      trace is one hop
- [ ] `/health/live` and `/health/ready` are meaningful and never consume budget —
      `spec/requests/health_spec.rb`
- [ ] `/status` reports window status, poll state, per-class ledger state, pending/skipped
      counts, and coverage percentages by the defined formulas — without initiating GitHub
      requests — `spec/requests/status_spec.rb`, `Github::Enrichment::Coverage`
- [ ] During §1's empty-volume fixture phase, while the worker has never been started, hash
      the complete budget row and record all request counters. Call `/health/live`,
      `/health/ready`, and `/status` repeatedly, then require the hash and counters to be
      byte-for-byte unchanged. A running worker is a concurrent writer and invalidates this
      measurement:

      ```bash
      docker compose exec -T db psql -U postgres \
        -d github_push_ingestor_development -Atc \
        "SELECT md5(COALESCE(row_to_json(b)::text, '')) FROM github_api_budget b;"
      docker compose exec -T db psql -U postgres \
        -d github_push_ingestor_development -Atc \
        'SELECT poll_used, enrichment_used, actor_share_used, repository_share_used FROM github_api_budget;'
      for endpoint in health/live health/ready status; do
        curl -fsS "http://localhost:3000/$endpoint" >/dev/null
        curl -fsS "http://localhost:3000/$endpoint" >/dev/null
        curl -fsS "http://localhost:3000/$endpoint" >/dev/null
      done
      docker compose exec -T db psql -U postgres \
        -d github_push_ingestor_development -Atc \
        "SELECT md5(COALESCE(row_to_json(b)::text, '')) FROM github_api_budget b;"
      docker compose exec -T db psql -U postgres \
        -d github_push_ingestor_development -Atc \
        'SELECT poll_used, enrichment_used, actor_share_used, repository_share_used FROM github_api_budget;'
      ```
- [ ] Retry behavior is visible — `github.retry_scheduled` / `github.retry_exhausted` at
      the default level
- [ ] Failures contain actionable context — every failure line carries classification,
      status, URL, attempt, and its `run_id` or entity id

---

## 5. Reviewer-experience gates — §16

- [ ] Clean checkout works — §1 above
- [ ] No local Ruby or PostgreSQL installation is required
- [ ] Commands match the assignment
- [ ] Plain `docker compose up --build` starts exactly `db`, `setup`, `web`, `worker` —
      `profiles: ["tools"]` on the other three
- [ ] `docker compose run --rm test` rebuilds through `pull_policy: build`, never touches the
      development databases (app or queue), and never triggers the development `setup`
      service — runtime comparison in §1 and `spec/docker_compose_spec.rb`
- [ ] Documentation is accurate; the README points to the plan and its appendix revision
      record
- [ ] Every repository-local Markdown target and heading anchor resolves; verify the final
      GitHub-rendered README, design brief, ADR links, and Mermaid architecture figure after
      the hardening PR merges
- [ ] Render `docs/DESIGN_BRIEF.md` temporarily as US Letter at 11pt with 0.75-inch margins;
      `pdfinfo` reports at most two pages, and visual inspection finds no clipping, overlap,
      malformed table, or awkward page break. The QA PDF is not committed
- [ ] No secrets or token are required
- [ ] Tests are deterministic — WebMock denies net connect; no VCR; fixture rate-limit
      resets are relative, so the corpus does not rot
- [ ] GitHub Project and issues show organized execution
- [ ] Pull requests are focused and linked to issues — every merged PR carries `Closes #`

---

## 6. Final repository review — §16

- [ ] **No secrets**

      ```bash
      docker compose run --rm test bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error
      docker compose run --rm test bin/bundler-audit

      find . -type f \( -name '.env' -o -path '*/config/master.key' \) -print
      token_pattern='([g]hp|[g]ho|[g]hu|[g]hs|[g]hr)_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|Authorization:[[:space:]]*(Bearer|token)[[:space:]]+[A-Za-z0-9._~+/-]{20,}|BEGIN [A-Z0-9 ]*PRIVATE KEY'
      git grep -nEI "$token_pattern" -- .
      git log -p --all | grep -nEI "$token_pattern"
      git log --all --name-only --pretty=format: | \
        grep -nE '(^|/)\.env$|(^|/)config/master\.key$'
      ```

      Every search must print nothing; the `grep` searches exiting 1 means no match and
      passes. Any output is a stop-ship finding, not something to redact in place.

- [ ] **No personal access token** — `git grep -n "Authorization" -- app lib config` returns only
      the SSRF-policy and header code
- [ ] **No stale documentation**

      ```bash
      git grep -nEI '[l]ands with PR|[a]vailable now|[P]lanned contents|after PR [0-9]+ merges|PR 12 [(]design brief[)]' -- README.md docs
      ```

      returns nothing.
- [ ] **No dead or speculative infrastructure**
- [ ] **No misleading guarantee of complete upstream event capture** — see §7
- [ ] **No claim of exactly-once execution** — see §7
- [ ] **No claim that enrichment coverage is complete** — see §7
- [ ] **No failing or flaky tests** — the suite run three times consecutively green,
      including a fixed-seed repeat

---

## 7. Forbidden-claim scan

```bash
claim_pattern='exactly[ -]?once|effectively[ -]?once|once-only[[:space:]]+(execution|processing|delivery)|(complete|full|exhaustive)[[:space:]]+(upstream[[:space:]]+)?(event[[:space:]]+)?capture|captur(e|es|ed|ing)[[:space:]]+(all|every)[[:space:]]+(upstream[[:space:]]+|public[[:space:]]+|GitHub[[:space:]]+)?events?|(complete|full|exhaustive)[[:space:]]+enrichment([[:space:]]+coverage)?|enrich(es|ed|ing)?[[:space:]]+(all|every)[[:space:]]+(actors?|repositories|entities)|sampling[[:space:]]+becomes[[:space:]]+coverage|100%[[:space:]]+(capture|enrichment|coverage)'
git grep -nI -i -E "$claim_pattern" -- .
```

**The rule: every prose hit must explicitly reject the guarantee.** The regex assignment
itself is scan vocabulary, not a claim. Any affirmative system-level promise of singular
execution, exhaustive upstream capture, or exhaustive enrichment fails the gate; do not
approve it merely because it avoids one exact phrase.

- [ ] Every hit is a negation
