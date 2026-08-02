# Live staged batch enrichment verification

```text
Probe date:       2026-08-02 (UTC)
Runtime:          working tree of agent/durable-enrichment-backlog (issue #45)
                  parent commit a18382e525a9642d376fa05b9c081b552f6a2ad5
Run window:       2026-08-02T20:20:35Z → 2026-08-02T20:27:00Z  (phase A)
                  2026-08-02T20:35:29Z → 2026-08-02T21:01:30Z  (phase B)
Docker:           28.3.0
Docker Compose:   2.38.1-desktop.1
API version:      2022-11-28
Authorization:    none sent
GitHub mode:      live
Isolation:        two fresh Compose projects, each with a fresh PostgreSQL volume;
                  the development stack was stopped for the duration so the probes
                  owned the outbound IP's quota
```

## Questions

1. Does one unauthenticated Search request actually settle a whole batch of entities,
   at the fill ratio Appendix G's capacity hypothesis assumes?
2. Are the Search rate-limit headers a separate resource from `core`, and does the
   application account for them separately?
3. Does a renamed or unsearchable identifier reach the payload-URL fallback and resolve
   there, rather than looping on the Search lane?
4. Does queued work survive quota exhaustion and a database restart unchanged?
5. Under a sustained run at the shipped defaults, does the measured completion rate
   exceed the measured arrival rate, with a negative backlog slope while draining?

Questions 1–4 are answered **yes** below. Question 5's answer is recorded in
[Phase B](#phase-b--sustained-catch-up-measurement) from the measurement itself, not
from the capacity arithmetic.

## Method and safety boundary

Both phases used the current working-tree image and explicitly named Compose projects
(`gpi-live-a`, `gpi-live-b`), each created and destroyed with its own volume. Phase A ran
`db` plus one-shot commands only — no `web`, no `worker` — so every outbound request was
one this transcript names. Phase B ran the full topology at the shipped defaults.

Sanitization: aggregate counts, stable GitHub ids, classifications, stage names, and
rate-limit fields are reproduced verbatim. Response bodies and third-party logins are not,
except where a login is itself the finding (`github-actions[bot]`, `facebook/react`) and is
already public.

Budget accounting for the whole session: 2 core polls, 3 core detail requests, and 14
Search requests in phase A; phase B stayed inside the shipped per-window allowances by
construction (12 poll and the detail-fallback allowance per hour on `core`, 8 spendable
per minute on `search`).
Neither phase approached the 60/hour core limit.

## Phase A — staged path, boundaries, and durability

### One poll, 176 cold entities, zero enrichment requests

```text
event=ingestion.run_completed  events_received=99  push_events_seen=92  events_created=92
event=budget.window_initialized  rate_limit_resource=core  rate_limit_limit=60
                                 rate_limit_remaining=59  rate_limit_used=1  poll_used=1

cold_actors=84  cold_repos=92  total=176
stages_actor={"batch_pending" => 84}
stages_repo={"batch_pending" => 92}
observations={"event" => 184}
sample_repo={"github_id":1320389400,"full_name":"reddupney66/gfkapf",
             "owner_login":"reddupney66","enrichment_stage":"batch_pending"}
```

`owner_login` is derived locally from the event's `repo.name`; 184 event-source
observations committed with the events. No enrichment request had been issued at this
point — the derivation-first stage costs no quota.

### One Search request settles nine actors; one settles ten repositories

```text
event=enrichment.fallback_admitted  entity_type=actor  github_actor_id=41898282
                                    reason=missing_search_result  enrichment_batch_id=1
event=enrichment.batch_completed  entity_type=actor  batch_id=1
        requested_count=10 returned_count=9 valid_count=9 fallback_count=1
        incomplete_results=false
event=enrichment.batch_completed  entity_type=repository  batch_id=2
        requested_count=10 returned_count=10 valid_count=10 fallback_count=0
        incomplete_results=false
```

The persisted batch envelopes carry the answer to question 2:

```text
batch=1 kind=search/actor      status=succeeded req=10 ret=9  valid=9  miss=1
        total_count=9  incomplete=false  rl_resource=search rl_limit=10 rl_remaining=9
batch=2 kind=search/repository status=succeeded req=10 ret=10 valid=10 miss=0
        total_count=10 incomplete=false  rl_resource=search rl_limit=10 rl_remaining=9
core_ledger=poll_used=1 enrichment_used=0
```

`x-ratelimit-resource: search` with a limit of **10**, reconciled onto the search ledger
while the core ledger's enrichment counter stayed at zero. Nineteen entities reached the
useful-data contract for two requests, and the contract fields are populated from the
search items themselves:

```text
completed_actor={"github_id":311997514,"account_type":"User",
                 "enrichment_status":"complete","latest_observation_source":"search"}
completed_repo={"github_id":1320389400,"language":null,"fork":false,"archived":false,
                "default_branch":"main","owner_github_id":311997514}
```

`language: null` is a valid contract value, not a gap: the contract is "a valid response
was durably observed", never "every nullable field is populated".

### A full cycle: 74 entities in 42.5 seconds, stopping at the reserve

The production loop (`Github::Enrichment::CycleRunner`, what `EnrichmentCycleJob` runs)
against the remaining backlog:

```text
before={"actor":74,"repo":0}
cycle={"batches_attempted":8,"batches_completed":8,"batches_deferred":0,"batches_failed":0,
       "items_requested":74,"items_valid":74,"fallbacks_admitted":0,
       "details_attempted":1,"details_completed":0,"details_terminal":1,
       "batch_stop_reason":"search_blocked","detail_stop_reason":"no_detail_work",
       "duration_ms":42518}
after={"actor":0,"repo":0}
search_ledger={"limit":10,"remaining":2,"request_ceiling":10,"reserve":2,"used":8,
               "available":0,"blocked_until":"2026-08-02T20:26:21Z"}
```

**74 requested, 74 valid — a fill ratio of 1.00** across eight paced requests, stopping
cleanly when the observed `remaining` reached the configured reserve rather than by
running the limit to zero. This is the capacity hypothesis measured rather than assumed:
8 spendable requests per minute at a batch size of 10 is an **80/minute ceiling**, and the
sample reached it.

### Two defects this phase found

Both were invisible to design review and to the offline corpus, and both are fixed and
covered by regression tests in the same change.

**1. An unparsable payload URL was treated as retryable.** The actor `github-actions[bot]`
carries a login with brackets, so the URL its own event supplies is not a valid URI and
`Github::UrlPolicy` refuses it before the request gate:

```text
event=enrichment.detail_retry_scheduled  github_actor_id=41898282  detail_attempts=1
      reason=refused "https://api.github.com/users/github-actions[bot]": unparsable
```

The refusal is correct; the disposition was not. §10 classifies a policy violation as
permanent, and the ladder would have spent three of the four hourly core detail requests
re-refusing the same stored string. `DetailRunner` now terminates on
`not_found`, `client_error`, and `permanent_error` alike.

**2. A batch of entirely unsearchable identifiers answered 422, not an empty result.**
Seeding `facebook/react` — which redirects to `react/react` — as the only pending
repository produced:

```text
url=https://api.github.com/search/repositories?q=repo%3Afacebook%2Freact&per_page=1
status=422
body={"message":"Validation Failed","errors":[{"message":"The listed users and
      repositories cannot be searched either because the resources do not exist or you
      do not have permission to view them.", ... }]}
```

The exploratory probe never saw this because a batch of ten simply omits its unsearchable
members. Treating it as a generic client error left the rename retrying on the Search lane
forever — the one path that can never resolve it. A 422 carrying that signature is now
read as "every requested identifier is missing", and the members are admitted to the
fallback exactly as an omitted item is:

```text
event=enrichment.fallback_admitted   github_repository_id=10270250
      reason=unsearchable_identifier  enrichment_batch_id=5
event=enrichment.batch_unsearchable  entity_kind=repository  response_status=422
event=enrichment.detail_completed    github_repository_id=10270250  detail_attempts=1

react={"github_id":10270250,"full_name":"facebook/react","enrichment_status":"complete",
       "enrichment_stage":"contract_complete","language":"JavaScript",
       "default_branch":"main","owner_github_id":102812,
       "latest_observation_source":"detail"}
```

The fallback followed the stored payload URL through GitHub's redirect and validated the
result against the stable id — the rename resolved without ever constructing a URL from a
mutable name.

### Quota boundary and restart durability

With the search ledger blocked at its reserve, five pending rows were fingerprinted, the
database container was restarted, and the fingerprint recomputed:

```text
BEFORE pending=5 fingerprint=ac3f8d66c6f93e225ec507ccc4d0fafb
BEFORE search_ledger used=8 blocked_until=2026-08-02T20:26:21Z
--- docker compose restart db ---
AFTER  pending=5 fingerprint=ac3f8d66c6f93e225ec507ccc4d0fafb
AFTER  search_ledger used=8 blocked_until=2026-08-02T20:26:21Z
AFTER  batches={["search","succeeded"]=>10, ["search","failed"]=>2,
                ["detail","succeeded"]=>1, ["detail","failed"]=>2}  observations=278
```

Identical fingerprint, identical ledger state, and every batch envelope and observation
retained. Quota exhaustion deferred work; it did not terminate any of it.

A forced poll during the same window was refused by the poll class's own allowance
(`deferral_reason=poll_class_blocked_until`) — enrichment pressure never borrows from
polling, and neither does an operator's `--force`.

### A third defect, found by the topology rather than the API

Phase B initially made no progress at all: recurring jobs accumulated in
`solid_queue_ready_executions` while both workers registered, heartbeated, and claimed
nothing. `config/queue.yml` declared `queues: polling,control` as a bare string, and
`SolidQueue::QueueSelector` wraps its input in `Array()` — so that worker was polling for
one queue literally named `"polling,control"`, which no job is ever enqueued into.

This predates issue #45 (the file is untouched by this change), and it means the always-on
`worker` container never polled or reconciled: only the single-name `enrichment` worker
functioned. The suite did not catch it because the spec split the configured string itself
and so asserted the author's intent rather than the runtime's reading of it. The queue is
now declared as a YAML list, and both queue specs assert through
`SolidQueue::QueueSelector` and `Array()` instead.

## Phase B — sustained catch-up measurement

Full topology (`db`, `web`, `worker`) at the shipped defaults, sampling `GET /status`
every 60 seconds. `/status` performs no writes and issues no GitHub request, so sampling
cannot perturb the run.

Configuration: the shipped defaults **at the time of the run**, which included
`CORE_DETAIL_FALLBACK_ALLOWANCE=4`. That value is what this measurement put under
pressure, and the result is why the default is now 40 — see "What the measurement
changed" below.

```text
Run window:        2026-08-02T20:35:29Z → 2026-08-02T21:01:30Z  (26 minutes)
Samples:           53, 24 of them past CATCH_UP_MIN_SAMPLE_SECONDS. Two sampling
                   loops were running against the same endpoint, so the effective
                   cadence was ~30s rather than the 60s each loop used; the
                   duplicates are harmless to the counts below, which are read from
                   the last sample rather than summed across samples.
Trailing window:   ENRICHMENT_METRICS_WINDOW_SECONDS = 3600

Arrivals:          872 entities
Completions:       865
Terminal outcomes: 5
Exits:             870  (99.8% of arrivals)
Arrival rate:      1,975.58 / hour   (measured, trailing window)
Completion rate:   1,959.72 / hour   (measured, trailing window)
Backlog delta:     +2 at the final sample

Search batches:    45 actor + 47 repository = 92 requests
Items requested:   429 actor + 443 repository = 872
Fill ratio:        0.981 actor, 0.986 repository
Missing items:     8 actor + 6 repository = 14  (1.6% of requested)
Detail fallbacks:  6 actor + 7 repository = 13 requests
Observations:      1,797 rows
Core ledger:       poll_used 2 of 12, detail_fallback used 4 of 4
```

**Verdict across the 24 mature samples: 8 `keeping_up`, 16 `not_keeping_up`.** The
verdict oscillates, and the reason is visible in the numbers rather than a mystery: the
Search lane requested 872 items across 92 requests and had 858 of them returned and
applied directly, sending the other 14 to the fallback, and it drained each five-minute
arrival burst within roughly two minutes. The pipeline as a whole produced 870 exits,
leaving two entities outstanding at the final sample — a residue that Search does not
return, waiting on the detail lane. With that lane capped at 4 requests an hour,
the residue outlives the window it arrived in, and any sample taken while it is
outstanding reports a positive backlog delta.

At the final sample the outstanding work was exactly two repositories, both
`detail_pending` with `missing_search_result`, and the core detail lane reading 4 of 4
used. Nothing was stuck: everything was deferred, durably, by a budget doing what it was
configured to do.

**Question 5 answered honestly: the Search lane keeps up; the service as configured
during this run did not, and it said so.** `/status` reported `not_keeping_up` in exactly
the samples where the backlog had not returned to zero — no eventual-catch-up claim was
made, and none is made here.

### What the measurement changed

At a 1.6–1.9% miss rate and roughly 2,000 arrivals an hour, the fallback lane needs on the
order of 40 requests an hour. It had 4. The core budget leaves exactly 40 after polling
(12) and the reserve (8) — the same allocation the pre-staged design spent on *every*
entity, which the staged path needs only for the residue — so
`CORE_DETAIL_FALLBACK_ALLOWANCE` now defaults to 40.

This is arithmetic from a measured miss rate, not a measured outcome: the sustained run
above was performed at 4, and no equivalent run at 40 was performed within this session's
unauthenticated quota. Even 40 does not guarantee the residue clears at peak arrival
rates, which is the honest reason `/status` publishes a measured verdict rather than a
promise.

## Caveats

- One sample, one IP, one feed. Arrival rates on GitHub's public feed vary by hour; a
  measurement is evidence about the window it covers, not a guarantee about future ones.
- The catch-up verdict published by `/status` is a comparison of measured rates over a
  trailing window. It is deliberately not a forecast, and no drain estimate is published
  anywhere in this service.
- Search returns items the query matched; an entity absent from GitHub's search index is
  handled by the fallback rather than by a larger batch.
