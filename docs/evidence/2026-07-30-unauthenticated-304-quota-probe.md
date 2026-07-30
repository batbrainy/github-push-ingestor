# Unauthenticated `304` responses consume GitHub rate-limit quota

```text
Probe date:    PENDING (UTC)
Endpoint:      GET https://api.github.com/events?per_page=100
API version:   2022-11-28 (sent explicitly)
Authorization: none sent
Captured by:   script/probe_304.sh
Cited by:      README.md; docs/adr/0004-class-aware-budget-ledger.md;
               docs/adr/0006-decomposed-poll-deferral-state.md
```

> **This transcript is not yet filled in.** Run `script/probe_304.sh --confirm` and paste
> its output into the two sections marked `PENDING` below. It spends three of the running
> machine's sixty unauthenticated requests per hour.

## Why this probe exists

GitHub's events documentation states generally that `304` responses do not count against
the rate limit. Its REST best-practices documentation scopes that exemption to requests
"correctly authorized with an `Authorization` header". This service sends no token, so the
two statements disagree about exactly the population of requests it makes — and the
difference decides whether an ETag is a quota saver or only a bandwidth saver.

`IMPLEMENTATION_PLAN.md` §10 records two dated unauthenticated probes from 2026-07-28
showing `x-ratelimit-used` incrementing across a `304`, and makes re-running the probe a
required validation gate for PR 6 so the design cites first-party evidence rather than a
review artifact.

## What was measured

PENDING — fill in from the raw dumps below.

| # | Request | GitHub `Date` (UTC) | Status | `x-ratelimit-used` | `x-ratelimit-remaining` | `ETag` |
|---|---|---|---|---:|---:|---|
| R1 | `GET`, no `If-None-Match` | | `200` | | | |
| R2 | `GET`, `If-None-Match: <R1 ETag>` | | `304` | | | |
| R3 | `GET`, `If-None-Match: <R1 ETag>` | | `304` | | | |

```text
x-ratelimit-limit:     PENDING
x-ratelimit-resource:  PENDING   (must read `core` — the bucket Github::BudgetLedger reconciles against)
x-ratelimit-reset:     PENDING   (epoch)  =  PENDING (UTC)
x-poll-interval:       PENDING   (corroborates §9's "observed 60")
```

GitHub's `Date` response header is the authoritative timestamp — it is independent of the
probing machine's clock. The local clock is recorded alongside each request only to
establish ordering.

## Method

Three requests, roughly two seconds apart:

| # | Request | What it establishes |
|---|---|---|
| R1 | `GET`, no `If-None-Match` | The baseline `used`, and the ETag to replay |
| R2 | Same URL, `If-None-Match: <R1 ETag>` | **The finding** — a `304` whose `used` is one higher |
| R3 | Same URL, `If-None-Match: <R1 ETag>` | The control — the increment is per-`304`, not a one-off |

Two requests would be the theoretical minimum. R3 costs one more of sixty and answers the
first question a skeptical reader asks: could another client behind the same IP have made
a request between R1 and R2? R3 does not eliminate that — nothing can, from one IP — but a
coincidental co-tenant increment on *both* intervals is implausible.

Headers sent on all three, and on nothing else:

```text
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2022-11-28
User-Agent: github-push-ingestor
```

The `User-Agent` is byte-identical to `Github::Request::PROTOCOL_HEADERS`, so this is
evidence about the requests this application actually makes rather than about a
differently-identified client. **No `Authorization` header is sent** — that is the entire
point, since the documented exemption is scoped to requests that carry one. A normal `GET`
is used rather than `curl -I`, which would send `HEAD`.

**Redaction rule.** `x-github-request-id`, `set-cookie` and `x-runtime-rid` are replaced
in place with `<redacted>`, keeping the header name so this dump cannot be mistaken for a
complete one that happened to contain nothing. Every `x-ratelimit-*` header, `date`,
`etag`, `x-poll-interval` and `x-github-api-version-selected` is verbatim. **No response
body was captured**: `/events?per_page=100` returns roughly ninety real events with real
logins, avatar URLs embedding numeric user IDs, and repository names, and the finding does
not need any of it. The probing IP address is deliberately not recorded.

PENDING — paste the `## Raw response headers` block from `script/probe_304.sh` here.

## Finding

PENDING — state it in one sentence once the numbers are in, in this form:

> Under `X-GitHub-Api-Version: 2022-11-28`, on `PENDING (UTC)`, from a single
> unauthenticated client, `x-ratelimit-used` increased by one across each `304 Not
> Modified` returned for a conditional request to `/events`.

## What this does not show

- **n = 3 requests, one IP, one date, one API version (`2022-11-28`), one endpoint
  (`/events`).** This is an observation of behaviour on a date, not a statement about
  GitHub's contract.
- **Unauthenticated only.** It does not contradict GitHub's statement that correctly
  authorized `304`s are exempt: the two statements describe different populations of
  request. This project holds no token and therefore cannot test the authenticated case.
- **The IP is shared.** Any request another client behind the same address made between R1
  and R2 would also increment `used`. R3 makes a coincidence on both intervals implausible;
  it does not eliminate it.
- **The probe did not observe the 60-second `X-Poll-Interval` floor** between its own three
  requests, once, under a bounded three-request budget. The running application does obey
  it (`event_sources.poll_floor_until`, §9).

The implementation's response is conservative in the safe direction. Budgeting a `304` that
turns out to be free wastes at most one request-attempt per poll; not budgeting one that is
in fact charged overruns a sixty-request hour and earns a `403`.

## Reproducing it

```bash
script/probe_304.sh --confirm
```

It refuses to run under `CI`, requires `--confirm`, writes no file, and captures no response
body. `spec/network_boundary_spec.rb` asserts that nothing in the test suite, in
`config/ci.rb`, in `bin/ci`, or in the GitHub Actions workflows references it.
