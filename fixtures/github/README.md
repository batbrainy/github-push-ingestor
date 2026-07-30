# Deterministic GitHub corpus

Hand-authored static JSON, pinned by `IMPLEMENTATION_PLAN.md` §2A and §12. VCR is
deliberately not used: scripted conditional responses, changing rate-limit headers, and
failure sequences have to be *authored*, not recorded.

One corpus serves three consumers, which is what §12 requires:

1. WebMock stubs in unit specs, so the live Faraday transport is exercised against the
   exact bytes the offline transport serves.
2. `Github::Transports::Fixture`, in integration specs.
3. `GITHUB_MODE=fixture` at runtime, for the reviewer's offline scenario.

It lives at the repository root rather than under `spec/`, because in fixture mode it is
runtime data read by the `web` and `worker` containers. Excluding `spec/` from the image
is a normal future hardening step and must not be able to break the demo.

## Layout

```
fixtures/github/
├── README.md
├── manifest.json      routing, headers, and response sequences
└── bodies/            response bodies, one JSON document per file
    ├── events/        event pages returned by /events
    ├── users/         actor documents returned by /users/:login
    ├── repos/         repository documents returned by /repos/:owner/:name
    └── errors/        GitHub's error bodies for 403, 404, and 500
```

## How a request finds a response

The manifest is keyed by a **canonical request key**: the request path, then its query
parameters sorted by name. Scheme and host are omitted because `Github::UrlPolicy` has
already proved them — `https` and `api.github.com` in live mode, `fixture` and
`api.github.com` offline. One entry therefore answers a request from either transport.

Body paths are **authored in the manifest and never derived from a URL**. That is a
security property rather than a convenience: `fixture://api.github.com/../../etc/passwd`
parses with its path preserved, and a corpus that derived filenames from URLs would read
it. Here that URL is simply a miss, and the loader additionally refuses any manifest
whose body path escapes `bodies/`.

An unknown key raises `Github::Errors::FixtureMiss`. Fixture mode **fails closed** — it
never falls back to live GitHub (§6).

## Relative header values

A header value of `+N` resolves to `N` seconds from now, in epoch seconds. Only
`x-ratelimit-reset` uses it, and it is the one thing in the corpus that is not
byte-static.

A fixed reset epoch would be in the past by the time anyone runs the demo, and the
ledger would then correctly roll the window on every single poll — so counters would
never accumulate and fixture mode would stop demonstrating the very accounting it exists
to demonstrate. The transport's clock is injectable, so specs stay deterministic.

## Sequences

A key's value is an ordered list. The *n*th request for that key gets the *n*th entry,
and the last entry repeats forever, so a long-running fixture container stays defined
rather than erroring after N polls. The cursor lives on the transport instance, never at
class level, so one spec cannot advance another's script under random ordering. This maps
exactly onto WebMock's multi-value `to_return`, which is sequential with a repeating last
element.

Conditional matching on `If-None-Match` was deliberately rejected. Positional scripting is
fully deterministic, and the assertion worth making — "the request carried the stored
ETag" — is better made against the fixture transport's recorded requests.

## URLs inside bodies

Every URL inside an event payload, and every `Link` header target, is a real
`https://api.github.com/...` URL. The `fixture` scheme is an addressing detail of the
offline transport, produced only by `Github::EventSources::FixtureEvents` and by
`Github::UrlPolicy.validate_payload_url!` after the full live policy has passed.

Two consequences: a database written in fixture mode is indistinguishable from one written
live, and a response body cannot forge a corpus address — a payload claiming a `fixture://`
URL is refused as `scheme_not_allowed`.

## Scenarios

`GITHUB_FIXTURE_SCENARIO` selects one. A scenario lists only what it overrides and
inherits the rest from `default`, resolved exactly one level so its behaviour stays
readable in one place.

| Scenario | What it exercises |
|---|---|
| `default` | One page of events, then `304` with the same ETag forever. The reviewer scenario. |
| `paginated` | `Link`-driven pagination: page 1 → page 2 → an empty page 3 (PR 6). |
| `rate_limited` | `403` with `x-ratelimit-remaining: 0` — primary exhaustion (PR 6). |
| `secondary_rate_limited` | `403` with `Retry-After` and quota remaining — a secondary limit (PR 6). |
| `transient_failure` | `500`, `500`, then `200`: two retries, each its own reservation. |
| `transient_failure_exhausted` | `500` forever, so retries exhaust and the failure persists. |
| `redirecting_repository` | `301` to a renamed repository, re-validated before it is followed. |
| `hostile_redirect` | `301` off `api.github.com`, which `Github::UrlPolicy` must refuse. |

Scenarios beyond `default` exist because §12 names them as corpus contents; PR 6 and PR 11
are the PRs that consume most of them.

## What is in `bodies/events/page-1.json`

Eight event envelopes, deliberately mixed so PR 5's tolerant parser and quarantine
taxonomy have real material:

| Entry | Event id | Shape |
|---|---|---|
| 1 | `58000000001` | Well-formed `PushEvent`, 40-hex SHAs |
| 2 | `58000000002` | Well-formed `PushEvent`, 64-hex SHAs |
| 3 | `58000000003` | Well-formed `PushEvent` carrying an unknown extra field (`pusher_type`) |
| 4 | `58000000004` | `WatchEvent` — a non-push event to ignore and count |
| 5 | `58000000005` | `PushEvent` missing `head` |
| 6 | `58000000006` | `PushEvent` whose `head` is not a valid object name |
| 7 | `58000000007` | Envelope with no `type` at all |
| 8 | `58000000008` | Well-formed `PushEvent` for an actor and a repository that both 404 on enrichment |

`page-2.json` holds three more, one of which repeats event `58000000001` so duplicate
absorption across pages is exercisable.

The `PushEvent` payloads carry exactly the five fields the post-2025-10-07 API documents —
`repository_id`, `push_id`, `ref`, `head`, `before` — and no `commits` array.

**What each of those becomes once processed is PR 5's to define and assert.** This file
describes the corpus, not outcomes that no code produces yet.
