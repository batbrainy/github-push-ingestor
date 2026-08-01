# Post-merge verification — external findings report

Date: 2026-08-01 (UTC)

Status: Authoritative post-merge run of `docs/SUBMISSION_CHECKLIST.md` §1, §4.5, §5 (brief
render), §6, and §7 against the default branch, from a fresh clone

```text
Default-branch SHA:  88e2260c7f20fea06cdacb88d62132caaed1fc14
Clone:               fresh `git clone` into a newly created temporary parent directory
Run window (UTC):    2026-08-01T14:22:35Z → 14:30:35Z (8m00s, single uninterrupted run)
Docker version:      28.3.0 (Docker Desktop)
Compose version:     v2.38.1-desktop.1
Host:                Darwin 25.5.0 arm64 (macOS, Apple Silicon)
Local toolchain:     no host Ruby, PostgreSQL, or psql used at any point
```

Every gate below ran in the order listed, in one scripted pass; a failing assertion would
have aborted the run at that gate. Classification vocabulary is the checklist's: pass,
repository defect, environment issue, or documentation mismatch.

## Section 1 — authoritative clean-checkout verification

| Gate | Command / assertion | Salient output | Duration | Result |
|---|---|---|---|---|
| 1.1 | clone, `git rev-parse HEAD`, clean tree, no `.env`/`master.key` | HEAD `88e2260c`; porcelain empty | 1s | pass |
| 1.2 | `down -v --remove-orphans`; volume inspection must fail | `github-push-ingestor_pgdata` absent | 1s | pass |
| 1.3 | `docker compose build --no-cache --pull` | cold image built | 70s | pass |
| 1.4 | `docker image rm …-app:latest`; `up --build -d`; `ps --all` | second cold path recreated the image | 13s | pass |
| 1.5 | topology | exactly `db` healthy, `setup` exited 0, `web` healthy, `worker` running; no tools service | <1s | pass |
| 1.6 | `curl -fsS …/health/ready` | `{"status":"ok"}` | 3s | pass |
| 1.7 | live worker reaches GitHub, no token | `ingestion.run_completed`: 1 page, 100 events received, 97 push events created, 3 ignored, `next_poll_at` +5m; budget row debited | 61s | pass |
| 1.8 | fixture boundary: `down -v`, volume absent, `GITHUB_MODE=fixture up --build -d db setup web` | offline stack ready | 13s | pass |
| 1.9 | fixture ingest, captured via `tee` | `4 created / 3 quarantined / 1 ignored` | 3s | pass |
| 1.10 | `enrich --limit 6` | `complete 2 / permanent_failure 1` per entity class | 4s | pass |
| 1.11 | SQL state | exactly `4 / 3 / 3 / 3 / 3` | 1s | pass |
| 1.12 | replay after 60s poll floor, `ingest --force` | `Duplicates skipped: 4`; no `enrichment.reactivated` in captured output | 65s | pass |
| 1.13–1.17 | three suite runs (`run --rm --build test`, `run --rm test`, fixed seed 4242) with dev-DB observations before/after | 1,734 + 10 examples, 0 failures, three consecutive times; dev `push_events`, `solid_queue_jobs`, and `setup` container finish time unchanged | 87s | pass |
| 1.18 | empty volume, offline full stack, `GITHUB_MODE=fixture script/verify_recovery.sh --confirm` | 45 checks PASS, 0 FAIL; "Every check above passed."; worker `GITHUB_MODE=fixture` after | 134s | pass |
| 1.19 | `push_events` across `docker compose restart` | equal | 2s | pass |
| 1.20 | `push_events` across `down --remove-orphans` / `up --build -d` | equal | 12s | pass |

## Section 4.5 — endpoint budget isolation

`md5(row_to_json(github_api_budget))` and all four request counters were captured, the
three endpoints (`/health/live`, `/health/ready`, `/status`) were each called three times,
and the hash and counters were byte-identical afterward. The worker had never started in
this stack. Result: **pass**.

## Section 5 — design-brief render

`docs/DESIGN_BRIEF.md` (as tightened in the same change that adds this report) rendered to
PDF at US Letter, 0.75-inch `@page` margins, 11pt/1.35 sans-serif, browser default body
margin zeroed, GFM conversion via `marked`, Mermaid diagram rendered, printed with
headless Chrome. `pdfinfo`: **2 pages, 612 × 792 pts (letter)**; visual inspection found no
clipping, overlap, or malformed layout; the final paragraph ends on page 2. The QA PDF is
not committed. Result: **pass** (page count is renderer-dependent; parameters above
reproduce it).

## Sections 6 and 7 — final repository review

- `bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error` in the container:
  0 security warnings, 0 errors. `bin/bundler-audit` in the container: advisory database
  cloned fresh, no vulnerabilities. Result: **pass**.
- Secret scans — working tree token grep, `git log -p --all` token grep, and
  history-filename grep for `.env`/`master.key`: no matches. Result: **pass**.
- Stale-documentation grep: no matches. Result: **pass**.
- Forbidden-claim scan: 24 hits, each reviewed by hand; every hit is a negation, a stated
  limitation, or the scan's own vocabulary. No affirmative claim of singular execution,
  exhaustive capture, or exhaustive enrichment. Result: **pass**.

## What this run does not show

- One machine, one date, one operating system (macOS/arm64 with Docker Desktop). It does
  not demonstrate other hosts or architectures beyond what CI covers.
- The live phase observed one successful unauthenticated poll and its budget debit — a
  reachability and accounting check, not sustained live operation.
- Runtime behavior is attested at `88e2260c`. Changes after that SHA are documentation
  only — this report, a length-focused tightening of `docs/DESIGN_BRIEF.md`, and the two
  reference fixes pointing here — so every command a reviewer runs executes the verified
  runtime unchanged.
