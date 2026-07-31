# Submission checklist

Repository: https://github.com/batbrainy/github-push-ingestor

Verified against: `<default-branch SHA>`, `<date>`

Pre-flight for `IMPLEMENTATION_PLAN.md` §16. **Every box is checked against the default
branch after PR 12 merges, from a fresh clone into an empty directory — never against a
working tree.** A working tree can pass gates a clone would fail: an untracked `.env`, a
`config/master.key`, a stale image, a warm database volume.

---

## 1. Clean-checkout verification

- [ ] `git clone` of the default branch into an empty directory; `git status --porcelain`
      is empty
- [ ] No `.env`, no `config/master.key`, no token anywhere in the clone
- [ ] `docker compose build --no-cache --pull` succeeds — a genuinely cold image build with
      `BUNDLE_FROZEN=1` against the committed `Gemfile.lock`
- [ ] `docker compose up --build` starts exactly `db`, `setup`, `web`, `worker` — and
      nothing else
- [ ] `curl http://localhost:3000/health/ready` returns `{"status":"ok"}`
- [ ] `GITHUB_MODE=fixture docker compose run --rm ingest` reports **4 created, 3
      quarantined, 1 ignored** from an empty database
- [ ] `docker compose run --rm test` is green across both rspec invocations
- [ ] `docker compose down` then `up`, and `SELECT COUNT(*) FROM push_events` is unchanged
- [ ] No local Ruby, PostgreSQL, or `psql` was used at any point

Pre-merge run against `6eab84c`:
[`docs/evidence/2026-07-31-clean-checkout-verification.md`](evidence/2026-07-31-clean-checkout-verification.md).
It found and fixed a defect that made `docker compose up --build` fail from a cold image —
which is why this section is checked again, from a fresh clone, after the merge.

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
- [ ] Duplicate ingestion is safe — and duplicate replays never reactivate skipped entities
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
- [ ] Docker restart policies recover crashed `db`/`web`/`worker` automatically (verified by
      container kills) — `docs/evidence/2026-07-31-container-kill-recovery.md`
- [ ] Application restart preserves events — verification step 9
- [ ] Worker restart preserves pending work — `spec/recovery/worker_crash_lease_spec.rb`
- [ ] An event committed before a crash remains recoverable —
      `spec/recovery/crash_window_spec.rb`
- [ ] Advisory locks provably release on session death (tested) —
      `spec/recovery/advisory_lock_session_death_spec.rb`, real `pg_terminate_backend`
- [ ] Duplicate jobs do not duplicate durable data —
      `spec/recovery/duplicate_job_execution_spec.rb`
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
- [ ] `docker compose run --rm test` never touches the development databases (app or queue)
      and never triggers the development `setup` service — `spec/docker_compose_spec.rb`
- [ ] Documentation is accurate; the README points to the plan and its appendix revision
      record
- [ ] No secrets or token are required
- [ ] Tests are deterministic — WebMock denies net connect; no VCR; fixture rate-limit
      resets are relative, so the corpus does not rot
- [ ] GitHub Project and issues show organized execution
- [ ] Pull requests are focused and linked to issues — every merged PR carries `Closes #`

---

## 6. Final repository review — §16

- [ ] **No secrets**

      ```bash
      bin/brakeman
      bin/bundler-audit
      git log -p | grep -inE 'ghp_|github_pat_|ghs_|gho_|BEGIN [A-Z]+ PRIVATE KEY'
      ```

- [ ] **No personal access token** — `grep -rn "Authorization" app lib config` returns only
      the SSRF-policy and header code
- [ ] **No stale documentation**

      ```bash
      grep -rn "lands with PR\|available now\|Planned contents\|PR 12 (design brief)" README.md
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
grep -rniE "exactly.once|complete capture|complete(ly)? enrich" \
  README.md docs/ IMPLEMENTATION_PLAN.md CLAUDE.md
```

**The rule: every hit must be a negation.** A hit that asserts the claim fails the gate.

Legitimate existing hits are the disclaimers themselves — `README.md`'s "does not claim
exactly-once execution" and "not complete enrichment coverage", `CLAUDE.md`'s "Never claim
or code against exactly-once", `IMPLEMENTATION_PLAN.md` §8's "The system does not claim
exactly-once execution" and §16's four `No …` bullets, and
[ADR 0005](adr/0005-at-least-once-with-idempotent-writes.md)'s "this is not exactly-once
execution, and the system must never claim it is".

- [ ] Every hit is a negation

---

## 8. Submission email — POST-MERGE

> **Post-merge step.** Send only after PR 12 is merged into the default branch and §1 above
> passes against a fresh clone of that branch. Nothing in this repository sends it.

The subject uses a plain ASCII hyphen-minus, matching `IMPLEMENTATION_PLAN.md` §13 and §16
exactly. Do not let a formatter turn it into an en dash.

```text
To:      recruiter@strongmind.com
Subject: Full Stack Developer Candidate - Umang Brahmakshatriya

Hello,

Please find my submission for the Full Stack Developer take-home.

Repository: https://github.com/batbrainy/github-push-ingestor

It is a Rails 8.1 API-only service that ingests GitHub Push events from the
public Events API, persists raw and structured data in PostgreSQL, and
enriches actors and repositories inside an explicit unauthenticated request
budget. It runs from a clean checkout with one command:

    docker compose up --build

No token, no local Ruby, and no local PostgreSQL are required.

The README includes a step-by-step "How to verify it's working" walkthrough,
including a fully offline fixture scenario with exact expected counts.
docs/DESIGN_BRIEF.md is the two-page architecture summary; architecture
decisions are recorded under docs/adr/, and dated first-party verifications
are under docs/evidence/.

Thank you for your time.

Umang Brahmakshatriya
```

- [ ] Sent on `<date>`
