# Claude Code Instructions

Repository-level guidance for AI-assisted development on this project. Every rule
below traces to a section of `IMPLEMENTATION_PLAN.md`; when the two disagree, the
plan wins.

## Before making any change

1. Read `IMPLEMENTATION_PLAN.md` (repository root). It is the frozen execution
   plan; its pre-implementation revision history lives in Git and in its
   Appendices A–D, Appendix E records how the build diverged from it, and Appendix F
   supersedes the enrichment load-shedding policy with a durable backlog.
2. Read `docs/DESIGN_BRIEF.md` and the ADRs under `docs/adr/`.
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

Repeated observation and job execution are expected. State only the two proved ingestion
invariants: a duplicate GitHub event ID cannot create another `push_events` row, and that
duplicate cannot register entity activity.
Executions, ingestion runs, quarantine occurrence counts, budget debits, and logs may
repeat or change. Recovery before commit is conditional on the event remaining in a later
sliding-feed response. Never claim or code against exactly-once execution or universal
idempotency of persisted state.

### Duplicate-event invariants (plan §7)

- `push_events` inserts use `ON CONFLICT (github_event_id) DO NOTHING RETURNING id`.
- Entity activity fields (`last_seen_at`, `latest_event_at`) update only when
  `RETURNING` produced a row. Duplicate replays may refresh identity fields but must
  never register new entity activity.
- Quarantine identity is `payload_fingerprint` alone: SHA-256 of compact UTF-8
  JSON with recursively sorted object keys. One algorithm, no alternates.

### SSRF boundary (plan §10)

Enrichment fetches only validated URLs: HTTPS, host exactly `api.github.com`, no
userinfo, no non-default port, no IP literals, bounded re-validated redirects.
Fixture mode fails closed — never a live fallback.

### Durable enrichment backlog (plan §10, Appendix F)

Never-enriched entity rows remain actionable across quota windows. Select them FIFO by
`created_at ASC, id ASC`; quota or fairness denial defers rather than terminates. The
default hourly split is 12 polling requests, 40 backlog-enrichment requests, and 8 safety
reserve requests, with 20/20 actor/repository guarantees and borrowing. Do not schedule a
refresh while either class has never-enriched work.

## Database changes

Schema changes go through migrations with intentional indexes, constraints where
correctness depends on them, and tests for uniqueness and replay behavior (plan §7, §12).

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

## AI-assisted development workflow

AI tools are used to accelerate implementation, but engineering decisions remain
human-owned.

When making changes:

- Read and follow `IMPLEMENTATION_PLAN.md` before implementation.
- Keep changes aligned with the current PR's scope in the plan's ladder (§13).
- Do not create separate AI planning documents, AI transcripts, or AI-generated
  notes unless explicitly requested. Engineering decisions are preserved through
  code, tests, PR descriptions, and ADRs under `docs/adr/` — nowhere else.

For each pull request:

- Explain the implementation approach in the PR description.
- Include important tradeoffs and rejected alternatives when applicable.
- Link the related GitHub issue with a `Closes #<issue>` line in the PR
  description, so the merge closes the issue automatically.
- Ensure generated code has been reviewed and validated — verify behavior
  through tests before accepting it.
- Run the relevant tests before proposing merge.

### Per-issue implementation protocol

Implement ONLY the GitHub issue the PR is for (issue #X).

Before changing files:

1. List the files you plan to modify.
2. Explain why each file belongs to this issue.
3. Identify work explicitly deferred to later PRs.

Do not implement future PR scope.
Keep the PR reviewable.

Discipline that makes AI assistance safe here:

- Confirm external API claims against official documentation or dated live
  probes — this project's `304`-quota finding (plan §10) exists because a
  documented claim did not survive an unauthenticated probe.
- Prefer small, incremental, reviewable commits.
- Never let generated text overstate guarantees: no "exactly-once", no "complete
  capture", no "complete enrichment coverage" (plan §16).

AI assistance should improve speed and consistency, not replace architecture
review, testing, security review, or operational reasoning.

The workflow is:

```
issue → implementation → tests → PR description + review → merge
```

Not:

```
issue → AI plan document → AI notes → AI summary → code
```

## Before opening a pull request

Confirm:

- The change matches the linked issue's scope.
- The change matches `IMPLEMENTATION_PLAN.md`.
- No unrelated refactoring is included.
- Tests cover the important behavior and failure modes, and they pass.
- The Docker workflow still works, where applicable.
- Documentation is updated if behavior or architecture changed.
