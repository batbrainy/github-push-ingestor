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
runtime data read by the `web` and `worker` containers. Keeping runtime fixtures separate
also means an image that excludes test files cannot break the offline demo.

## Layout

```
fixtures/github/
├── README.md
├── manifest.json      routing, headers, and response sequences
└── bodies/            response bodies, one JSON document per file
    ├── events/        event pages returned by /events
    ├── users/         actor documents returned by /users/:login
    ├── repos/         repository documents returned by /repos/:owner/:name
    ├── search/        Search envelopes returned by /search/users and /search/repositories
    └── errors/        GitHub's error bodies for 403, 404, 422, and 500
```

## How a request finds a response

The manifest is keyed by a **canonical request key**: the request path, then its query
parameters sorted by name. Scheme and host are omitted because `Github::UrlPolicy` has
already proved them — `https` and `api.github.com` in live mode, `fixture` and
`api.github.com` offline. One entry therefore answers a request from either transport.

The two Search keys in `default` are the worked example:

```
/search/users?per_page=3&q=user%3Aoctocat+user%3Amonalisa+user%3Aghostuser
/search/repositories?per_page=3&q=repo%3Aoctocat%2FHello-World+repo%3Amonalisa%2FSpoon-Knife+repo%3Adeleted-org%2Fgone
```

`per_page` sorts before `q`, and the value is exactly what `URI.encode_www_form`
produces: the space between qualifiers becomes `+`, `:` becomes `%3A`, `/` becomes
`%2F`. A Search key therefore encodes the batch's exact membership and FIFO order
(`created_at, id` over the never-enriched backlog) — a claim that composes a different
batch, one entity more or fewer or in a different order, produces a different key and
fails closed as `Github::Errors::FixtureMiss` rather than quietly answering the wrong
batch. That strictness is deliberate: the corpus asserts the batch composition, not
just the endpoint.

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

## Search responses override the core headers

`default_headers` describes the core resource: `x-ratelimit-resource: core`, limit 60,
reset `+3600`. Search is a different rate-limit resource with a per-minute window, so
**every response scripted for a `/search/...` key overrides all five rate-limit headers
per response** — resource `search`, limit `10`, its own `remaining`/`used`, reset
`+60`. The override is per response rather than per scenario because header merging is
per response: the search budget ledger's `reconcile!` discards headers whose resource
is not `search`, and a search response that inherited the core defaults would either be
ignored by its own ledger or, worse, teach it core-window numbers.

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
| `default` | One page of events, then `304` with the same ETag forever; each Search batch answers two of its three entities, and the missing ones fall back to detail and meet `404`s. The reviewer scenario — the walkthrough below. |
| `paginated` | `Link`-driven pagination: page 1 → page 2 → an empty page 3. Page 2 repeats page 1's first event on purpose, which is how the absence of a stop-on-known-event is proved. |
| `paginated_final_page` | Page 1 → page 2, and page 2 carries no `Link` — the no-next-link stop, which `paginated` cannot show because its last page is empty first. |
| `rate_limited` | `403` with `x-ratelimit-remaining: 0` — primary exhaustion, which blocks every live request until the window resets. |
| `secondary_rate_limited` | `403` with `Retry-After` and quota remaining — a secondary limit, which blocks globally for the interval GitHub named. |
| `transient_failure` | `500`, `500`, then `200`: two retries, each its own reservation. |
| `transient_failure_exhausted` | `500` forever, so retries exhaust and the failure persists. |
| `search_complete` | Both Search envelopes return every requested entity, so the whole backlog completes in two requests and no detail fallback is admitted. |
| `search_renamed_repository` | Hello-World comes back with its id intact but as `octocat/hello-world-renamed` — a rename, which the batch validator refuses (`renamed_repository`) and hands to the detail fallback. |
| `search_unrequested_result` | The repository envelope carries the two requested items plus `intruder/unasked`, which nobody asked for — preserved as an `unrequested_result` observation and never applied. |
| `search_incomplete_results` | The users envelope sets `incomplete_results: true` over the same two items as `default` — ID-valid items are applied regardless, and the missing `ghostuser` still falls back. The flag is an envelope fact, not an item fact. |
| `search_malformed` | Parseable JSON that fails the Search envelope contract (`total_count` not a number, `incomplete_results` not boolean, `items` not an array) — the batch fails and every member is rescheduled. |
| `search_rejected` | `422 Validation Failed` on both Search keys — GitHub refused the query itself. |
| `search_rate_limited` | `403` on the search resource with `x-ratelimit-remaining: 0` — the per-minute search window is exhausted. |
| `search_secondary_rate_limited` | `429` with `Retry-After` and search quota remaining — a secondary limit against Search. |
| `redirecting_repository` | Hello-World is absent from the Search envelope, so the detail fallback fetches it and meets a `301` to the renamed repository, re-validated before it is followed. |
| `hostile_redirect` | The same Search miss, but the `301` points off `api.github.com`, which `Github::UrlPolicy` must refuse. |

Scenarios beyond `default` exist because §12 names them as corpus contents. The pagination
and rate-limit ones are consumed by `Github::Ingestion::PageLoop` and
`Github::RateLimitPolicy`. The two redirect scenarios also override the repository Search
key with `search/repositories-missing-hello-world.json`, because staged enrichment only
fetches a detail URL for an entity Search failed to answer — the Search miss is what keeps
the redirect boundary reachable. They are consumed by
`spec/services/github/enrichment/redirect_boundary_spec.rb`, which drives them through the
enrichment claim path rather than through the executor alone — so what is asserted is the
consequence for an *entity*: a rename reaches `complete` and is debited for both hops, while a
hostile `Location` reaches `permanent_failure` with the second hop never sent and the event
source still in service. Both also appear in the README's fixture scenario matrix as reviewer
commands.

## The default enrichment walkthrough

`GITHUB_MODE=fixture bin/ingest` persists four push events and stubs three actors
(octocat, monalisa, ghostuser) and three repositories (octocat/Hello-World,
monalisa/Spoon-Knife, deleted-org/gone). `GITHUB_MODE=fixture SEARCH_PACING_SECONDS=0
bin/enrich --limit 6` then walks the staged pipeline in four requests:

1. The actor Search batch answers `search/users-partial.json`: octocat and monalisa
   validate against their immutable ids and are applied; ghostuser is missing from the
   envelope and is admitted to the detail fallback.
2. The repository batch answers `search/repositories-partial.json` the same way.
   Spoon-Knife's item carries `"description": null` and `"language": null` — the proof
   that the nullable contract fields pass validation as nulls rather than being refused.
   `deleted-org/gone` is missing and falls back.
3. The two detail fallbacks fetch the stored payload URLs (`/users/ghostuser`,
   `/repos/deleted-org/gone`), meet the corpus's `404`s, and go terminal immediately.

End state, per class: two `complete`, one `permanent_failure` — from exactly two search
requests and two detail requests. `SEARCH_PACING_SECONDS=0` matters: the one-shot never
sleeps pacing out, so at the default 6 seconds the second batch would be reported as a
pacing deferral instead of running back to back.

## What is in `bodies/events/page-1.json`

Eight event envelopes, deliberately mixed so the tolerant parser and quarantine taxonomy
have real material:

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

The shipped processor outcomes are asserted in
`spec/services/github/ingestion_runner_spec.rb`: four event rows, one ignored non-push
event, and three quarantined envelopes with the classifications described above. Entity
enrichment outcomes are asserted in
`spec/services/github/enrichment/end_to_end_spec.rb`. This file remains the corpus contract;
the specs are the executable outcome contract.
