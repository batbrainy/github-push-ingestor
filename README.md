# github-push-ingestor

Fault-tolerant Rails service for ingesting, enriching, and persisting GitHub
Push events.

Polls GitHub's public Events API, processes `PushEvent` records, retains raw and
structured data in PostgreSQL, enriches actors and repositories within an
explicit unauthenticated request budget, and recovers cleanly from application
and worker crashes.

## Status

Foundation stage. This README is a skeleton; each section below is completed by
the pull request that ships the capability it documents. The authoritative
execution plan is [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) — its
pre-implementation revision history lives in Git and in its Appendices A–D.

## Planned contents

| Section | Lands with |
|---|---|
| Architecture summary | PR 2–5 |
| Requirements and clean-checkout startup (Docker Compose) | PR 2 |
| Environment variables (budget knobs, fairness shares, TTLs, `GITHUB_MODE`, `LOG_LEVEL`) | PR 2–7 |
| One-shot ingestion command (default, `--force`, deferred/busy semantics) | PR 5 |
| Continuous ingestion behavior and expected time before records appear | PR 6, 8 |
| Rate-limit behavior: allowance formula, budget table, global-vs-class blocking, per-window bootstrap | PR 6 |
| Test command and deterministic fixture verification with exact expected counts | PR 2, 11 |
| Log, API, and database inspection examples | PR 10, 12 |
| Crash-recovery verification (container kills) | PR 11, 12 |
| Known limitations (sampling-based enrichment, no complete-capture guarantee, shared-IP budget) | PR 12 |

## Reviewer commands (future)

Each command becomes available with the PR that ships it:

```bash
docker compose up --build        # PR 2
docker compose run --rm test     # PR 2 (real suite from PR 3)
docker compose logs -f           # PR 2
docker compose run --rm ingest   # PR 5
```

## Development

AI-assisted development guidance for this repository lives in
[`CLAUDE.md`](CLAUDE.md). Design brief and ADRs will live under `docs/`.

## License

[MIT](LICENSE)
