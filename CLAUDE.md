# Claude Code Instructions

Repository-level guidance for AI-assisted development on this project. Every rule
below traces to a section of `IMPLEMENTATION_PLAN.md`; when the two disagree, the
plan wins.

## Before making any change

1. Read `IMPLEMENTATION_PLAN.md` (repository root). It is the frozen execution
   plan; its revision history lives in Git and in its Appendices A–D.
2. Read `docs/DESIGN_BRIEF.md` and the ADRs under `docs/adr/` once they exist.
3. Do not change architectural direction, add infrastructure, or add dependencies
   without first updating the plan and stating the tradeoff.

## Stack (pinned — plan §2A)

- Rails 8.1 API-only, Ruby 3.4.10 (exact pin in `.ruby-version`, Dockerfile, CI)
- PostgreSQL 16 — the system of record
- Solid Queue in its own `queue` database inside the same Postgres container
- Faraday for HTTP; RSpec + WebMock + hand-authored static JSON fixtures (no VCR)
- GitHub REST API version header `X-GitHub-Api-Version: 2022-11-28`

Out of scope by decision (plan §2): Kafka, Redis, Sidekiq, Kubernetes, Prometheus,
Grafana, Elasticsearch, frontend frameworks, GitHub authentication. Do not
introduce them.

## Architecture rules

### Source of truth

PostgreSQL business tables are the durable record. Never treat HTTP responses,
queues, in-memory state, or logs as the source of business state. An event is
accepted only after its `push_events` row commits (plan §8).

### GitHub requests

Every live GitHub request — polling and enrichment, from poller, worker, or
one-shot — goes through `Github::RequestExecutor`:

```
request gate → budget ledger reservation → URL policy → transport
```

Never call GitHub directly from models, jobs, controllers, or anything outside
that chain (plan §5, §10). The budget ledger debits every outbound attempt —
including `304`s and retries — before execution; failures stay spent.

### Lock ordering (plan §2A, §5)

Allowed: `SourceLock` → `RequestGate`. Never the reverse. Enrichment jobs never
acquire `SourceLock` — they take only the request gate.

### Processing semantics (plan §8)

At-least-once execution + idempotent writes + unique constraints =
effectively-once persisted outcomes. Never claim or code against exactly-once
execution.

### Idempotency invariants (plan §7)

- `push_events` inserts use `ON CONFLICT (github_event_id) DO NOTHING RETURNING id`.
- Entity activity fields (`last_seen_at`, `latest_event_at`, reactivation) update
  only when `RETURNING` produced a row. Duplicate replays may refresh identity
  fields but must never reactivate a `skipped_budget` entity.
- Quarantine identity is `payload_fingerprint` alone: SHA-256 of compact UTF-8
  JSON with recursively sorted object keys. One algorithm, no alternates.

### SSRF boundary (plan §10)

Enrichment fetches only validated URLs: HTTPS, host exactly `api.github.com`, no
userinfo, no non-default port, no IP literals, bounded re-validated redirects.
Fixture mode fails closed — never a live fallback.

## Database changes

Schema changes go through migrations with intentional indexes, constraints where
correctness depends on them, and tests for uniqueness/idempotency (plan §7, §12).

## Testing rules (plan §12)

- Deterministic only: WebMock plus the static fixture corpus. No live GitHub
  calls in tests, ever.
- The `test` compose service touches only the isolated test databases — never
  the development databases.
- Test failure paths (quota exhaustion, `304`s, retries, quarantine, crashes),
  not only happy paths.

## Pull request discipline (plan §3, §13)

One coherent capability per PR, mapped to the plan's PR ladder, squash-merged.
Do not mix refactoring, feature work, formatting, and unrelated cleanup. Use the
PR template; keep the plan and README accurate in the same PR that changes
behavior.

## AI usage rules

AI assistance is used throughout this repository. The discipline that makes that
safe:

- Validate generated code; verify behavior through tests before accepting it.
- Confirm external API claims against official documentation or dated live
  probes — this project's `304`-quota finding (plan §10) exists because a
  documented claim did not survive an unauthenticated probe.
- Prefer small, incremental, reviewable commits.
- Never let generated text overstate guarantees: no "exactly-once", no "complete
  capture", no "complete enrichment coverage" (plan §16).

## Before completing any change

Confirm: tests pass; the Docker workflow still works; documentation remains
accurate; the change matches `IMPLEMENTATION_PLAN.md`.
