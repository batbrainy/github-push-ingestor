# Unauthenticated `304` responses consume GitHub rate-limit quota

```text
Probe date:    2026-07-30 (UTC)
Endpoint:      GET https://api.github.com/events?per_page=100
API version:   2022-11-28 (sent explicitly)
Authorization: none sent
Captured by:   script/probe_304.sh
Cited by:      README.md; docs/adr/0004-class-aware-budget-ledger.md;
               docs/adr/0006-decomposed-poll-deferral-state.md
```

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

| # | Request | Status | `x-ratelimit-used` | `x-ratelimit-remaining` | `ETag` |
|---|---|---|---:|---:|---|
| R1 | `GET`, no `If-None-Match` | `200` | 4 | 56 | `W/"ce6813…abfd2"` |
| R2 | `GET`, `If-None-Match: <R1 ETag>` | `304` | **5** | 55 | same |
| R3 | `GET`, `If-None-Match: <R1 ETag>` | `304` | **6** | 54 | same |

```text
x-ratelimit-limit:     60
x-ratelimit-resource:  core        (the bucket Github::BudgetLedger reconciles against)
x-ratelimit-reset:     1785437524  =  2026-07-30T18:52:04Z
x-poll-interval:       60          (corroborates §9's "observed 60")
```

Local clock at each request: `18:44:09Z`, `18:44:12Z`, `18:44:14Z`.

**On timestamps.** All three responses carry the *same* `Date: Thu, 30 Jul 2026 18:44:10
GMT`, alongside `cache-control: public, max-age=300` and an unchanged
`last-modified: 18:39:08`. The `304`s echo the metadata of the cached representation rather
than stamping a fresh instant, so `Date` fixes the hour but **cannot order the three
requests** — the local clock above does that. That is not a weakness in the finding; it
sharpens it. The two `304`s were served from cache against an unchanged representation,
doing no origin work at all, and each still cost a request.

**`used` was already 4 after R1**, so three unauthenticated requests had been made from
this IP earlier in the same window by something other than this probe. The shared-IP
caveat below is therefore concrete rather than hypothetical.

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

## Raw response headers

Redacted in place, name kept: `x-github-request-id`, `set-cookie`, `x-runtime-rid`.
No response body was captured. No `Authorization` header was sent.

### R1 — unconditional GET

Local clock (UTC): 2026-07-30T18:44:09Z

```http
GET /events?per_page=100 HTTP/2
Host: api.github.com
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2022-11-28
User-Agent: github-push-ingestor

HTTP/2 200 
date: Thu, 30 Jul 2026 18:44:10 GMT
content-type: application/json; charset=utf-8
cache-control: public, max-age=300, s-maxage=300
vary: Accept,Accept-Encoding, Accept, X-Requested-With
etag: W/"ce681306fb999db3dc4c878fb15c5e6ea6fbe0ca3d19acfbdf30a8d7a06abfd2"
last-modified: Thu, 30 Jul 2026 18:39:08 GMT
x-poll-interval: 60
x-github-media-type: github.v3; format=json
link: <https://api.github.com/events?per_page=100&page=2>; rel="next", <https://api.github.com/events?per_page=100&page=3>; rel="last"
x-github-api-version-selected: 2022-11-28
access-control-expose-headers: ETag, Link, Location, Retry-After, X-GitHub-OTP, X-RateLimit-Limit, X-RateLimit-Remaining, X-RateLimit-Used, X-RateLimit-Resource, X-RateLimit-Reset, X-OAuth-Scopes, X-Accepted-OAuth-Scopes, X-Poll-Interval, X-GitHub-Media-Type, X-GitHub-SSO, X-GitHub-Request-Id, Deprecation, Sunset, Warning
access-control-allow-origin: *
strict-transport-security: max-age=31536000; includeSubdomains; preload
x-frame-options: deny
x-content-type-options: nosniff
x-xss-protection: 0
referrer-policy: origin-when-cross-origin, strict-origin-when-cross-origin
content-security-policy: default-src 'none'
server: github.com
accept-ranges: bytes
x-ratelimit-limit: 60
x-ratelimit-remaining: 56
x-ratelimit-used: 4
x-ratelimit-resource: core
x-ratelimit-reset: 1785437524
x-github-request-id: <redacted>
```

### R2 — conditional GET (the finding)

Local clock (UTC): 2026-07-30T18:44:12Z

```http
GET /events?per_page=100 HTTP/2
Host: api.github.com
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2022-11-28
User-Agent: github-push-ingestor
If-None-Match: W/"ce681306fb999db3dc4c878fb15c5e6ea6fbe0ca3d19acfbdf30a8d7a06abfd2"

HTTP/2 304 
date: Thu, 30 Jul 2026 18:44:10 GMT
content-type: application/json; charset=utf-8
cache-control: public, max-age=300, s-maxage=300
vary: Accept,Accept-Encoding, Accept, X-Requested-With
etag: W/"ce681306fb999db3dc4c878fb15c5e6ea6fbe0ca3d19acfbdf30a8d7a06abfd2"
last-modified: Thu, 30 Jul 2026 18:39:08 GMT
x-poll-interval: 60
x-github-media-type: github.v3; format=json
link: <https://api.github.com/events?per_page=100&page=2>; rel="next", <https://api.github.com/events?per_page=100&page=3>; rel="last"
x-github-api-version-selected: 2022-11-28
access-control-expose-headers: ETag, Link, Location, Retry-After, X-GitHub-OTP, X-RateLimit-Limit, X-RateLimit-Remaining, X-RateLimit-Used, X-RateLimit-Resource, X-RateLimit-Reset, X-OAuth-Scopes, X-Accepted-OAuth-Scopes, X-Poll-Interval, X-GitHub-Media-Type, X-GitHub-SSO, X-GitHub-Request-Id, Deprecation, Sunset, Warning
access-control-allow-origin: *
strict-transport-security: max-age=31536000; includeSubdomains; preload
x-frame-options: deny
x-content-type-options: nosniff
x-xss-protection: 0
referrer-policy: origin-when-cross-origin, strict-origin-when-cross-origin
content-security-policy: default-src 'none'
server: github.com
accept-ranges: bytes
x-ratelimit-limit: 60
x-ratelimit-remaining: 55
x-ratelimit-used: 5
x-ratelimit-resource: core
x-ratelimit-reset: 1785437524
x-github-request-id: <redacted>
```

### R3 — conditional GET again (the control)

Local clock (UTC): 2026-07-30T18:44:14Z

```http
GET /events?per_page=100 HTTP/2
Host: api.github.com
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2022-11-28
User-Agent: github-push-ingestor
If-None-Match: W/"ce681306fb999db3dc4c878fb15c5e6ea6fbe0ca3d19acfbdf30a8d7a06abfd2"

HTTP/2 304 
date: Thu, 30 Jul 2026 18:44:10 GMT
content-type: application/json; charset=utf-8
cache-control: public, max-age=300, s-maxage=300
vary: Accept,Accept-Encoding, Accept, X-Requested-With
etag: W/"ce681306fb999db3dc4c878fb15c5e6ea6fbe0ca3d19acfbdf30a8d7a06abfd2"
last-modified: Thu, 30 Jul 2026 18:39:08 GMT
x-poll-interval: 60
x-github-media-type: github.v3; format=json
link: <https://api.github.com/events?per_page=100&page=2>; rel="next", <https://api.github.com/events?per_page=100&page=3>; rel="last"
x-github-api-version-selected: 2022-11-28
access-control-expose-headers: ETag, Link, Location, Retry-After, X-GitHub-OTP, X-RateLimit-Limit, X-RateLimit-Remaining, X-RateLimit-Used, X-RateLimit-Resource, X-RateLimit-Reset, X-OAuth-Scopes, X-Accepted-OAuth-Scopes, X-Poll-Interval, X-GitHub-Media-Type, X-GitHub-SSO, X-GitHub-Request-Id, Deprecation, Sunset, Warning
access-control-allow-origin: *
strict-transport-security: max-age=31536000; includeSubdomains; preload
x-frame-options: deny
x-content-type-options: nosniff
x-xss-protection: 0
referrer-policy: origin-when-cross-origin, strict-origin-when-cross-origin
content-security-policy: default-src 'none'
server: github.com
accept-ranges: bytes
x-ratelimit-limit: 60
x-ratelimit-remaining: 54
x-ratelimit-used: 6
x-ratelimit-resource: core
x-ratelimit-reset: 1785437524
x-github-request-id: <redacted>
```

## Finding

Under `X-GitHub-Api-Version: 2022-11-28`, on 2026-07-30, from a single unauthenticated
client, `x-ratelimit-used` increased by one across **each** `304 Not Modified` returned for
a conditional request to `/events` — 4 → 5 → 6, with `x-ratelimit-remaining` falling 56 →
55 → 54 and `x-ratelimit-resource` reading `core` throughout.

This re-run confirms what `IMPLEMENTATION_PLAN.md` §10 recorded from the 2026-07-28 review
probes (a transcript showing 200 → used 4, conditional replay → 304, used 5). No amendment
to the plan's accounting decision was required.

## What this does not show

- **n = 3 requests, one IP, one date, one API version (`2022-11-28`), one endpoint
  (`/events`).** This is an observation of behaviour on a date, not a statement about
  GitHub's contract.
- **Unauthenticated only.** It does not contradict GitHub's statement that correctly
  authorized `304`s are exempt: the two statements describe different populations of
  request. This project holds no token and therefore cannot test the authenticated case.
- **The IP is shared, demonstrably so** — `used` stood at 3 before this probe began. Any
  request another client behind the same address made between R1 and R2 would also
  increment `used`. R3 makes a coincidence landing on *both* intervals implausible; it
  does not eliminate it.
- **The probe did not observe the 60-second `X-Poll-Interval` floor** between its own three
  requests, once, under a bounded three-request budget. The running application does obey
  it (`event_sources.poll_floor_until`, §9).
- **`Date` is identical across all three responses**, so nothing here proves the three
  requests were separated in time except the probing machine's own clock.

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
