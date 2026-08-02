# 13. Derivation-first staged batch enrichment over per-entity detail fetching

Date: 2026-08-02

Status: Accepted

## Context

PR #43's durable backlog (plan Appendix F) fixed the wrong-outcome problem, since quota
scarcity no longer terminates work, but not the capacity problem. The service model
underneath was still one core request per entity, at most 40 attempts per hour, against
Appendix A's cold-demand pressure sample of roughly 2,172 to 2,280 entity references per
hour. Durable-but-never-draining is honest and still unsatisfying: a no-token capacity
wall, with authentication explicitly out of scope.

A dated, live, unauthenticated probe of GitHub Search established the facts that make a
different shape possible:

- Repeated exact `user:` qualifiers in one `/search/users` request returned 5 of 5
  requested users, `incomplete_results: false`.
- Repeated exact `repo:` qualifiers in one `/search/repositories` request returned
  9 of 10 requested repositories, `incomplete_results: false`. The miss was
  `facebook/react`, which redirects to `react/react`, a rename, which is precisely why
  results must be validated against stable IDs and why a fallback lane must exist.
- Both responses reported `x-ratelimit-resource: search` with a limit of 10, a
  separate per-minute budget that the core ledger does not account for.
- Joining exact qualifiers with `OR` produced HTTP 422: the space-joined repeated
  qualifier is the supported batching form, not an optimization over it.

So up to ten entities can be resolved per request on a budget the ingestion pipeline was
not spending at all.

## Decision

Adopt derivation-first, lossless staged batch enrichment (plan Appendix G; issue #45):

1. Derive before fetching. Ingestion persists event-native identity, appends an
   event-source observation in the same transaction, derives every locally computable
   field, and coalesces demand by stable GitHub ID. Network requests are spent only on
   facts the stored payload does not determine.
2. Search batches are the normal path. Up to `SEARCH_BATCH_SIZE` (≤ 10) repeated
   exact qualifiers per request, never `OR`; results mapped and validated by stable
   integer ID, never by result order or mutable login/name alone.
3. Payload-URL detail fallback is the amendment, not the rule. Only missing,
   renamed, identity-mismatched, or contract-invalid batch items fetch their stored
   payload-provided `api_url`, through the core ledger's
   `CORE_DETAIL_FALLBACK_ALLOWANCE` (40/hour). No identifier is ever turned into a
   constructed detail URL; the polling allocation is never touched.
4. Dual ledgers. `github_api_budget` (core, hourly: 12 poll + 40 detail + 8 reserve
   = 60) and `github_search_budget` (search, per-minute:
   ceiling 10, reserve 2, 6-second pacing, header-less window roll), each reconciled
   only against headers naming its own resource, both behind the one global request gate.
5. Observations and projections split. Every raw item is an append-only
   `enrichment_observations` row (source `event | search | detail`, fingerprint,
   provenance, validation outcome); every request attempt is an `enrichment_batches`
   envelope (counts, `total_count`/`incomplete_results`, observed rate-limit headers).
   Entity tables remain the latest projection and point at their latest successful
   observation; a refresh repoints the projection and never overwrites retained
   evidence.
6. A stage machine with seven resting stages (`batch_pending`, `batch_in_flight`,
   `detail_pending`, `detail_in_flight`, `retry_scheduled`, `contract_complete`,
   `terminal`) under durable leases, with instant timestamps for the conditions no row
   rests in. Completion is the explicit useful-data contract per entity kind, nullable
   fields valid as nulls. Terminal outcomes exist only for entity-specific facts (a
   404/410 immediately; other detail failures after `DETAIL_FALLBACK_MAX_ATTEMPTS`);
   no quota-based terminal outcome exists anywhere.
7. Refresh rides the same batch path under the composition rule: own-class backlog
   fills first, TTL-stale refresh tops up spare slots only when neither class has
   claimable backlog, refresh-only batches only when neither has backlog at all.

## Consequences

What this buys:

- The theoretical service ceiling moves from 40 entities/hour to 4,800 items/hour
  (8 spendable search requests/minute × batches of 10), stated as a capacity
  hypothesis, since misses, fallback, retries, and pacing all subtract from it.
- Core polling is better protected than before: normal-path enrichment no longer
  competes on core at all, and what core enrichment may still spend is an explicit
  `CORE_DETAIL_FALLBACK_ALLOWANCE` cap rather than whatever the poll allowance and
  reserve happen to leave over.
- Every enrichment claim is auditable from durable state: what was asked, what came
  back, what validated, what was applied, and which raw evidence supports the current
  projection.
- A rename or identity mismatch is detected rather than silently applied, because
  application requires a stable-ID match.

What it costs, stated plainly:

- Roughly double the write volume per enriched entity (observation + projection + batch
  envelope), and three new tables to operate.
- Search documents are shallower than detail documents; the completion contract is
  deliberately narrower than a full profile, and fields outside it (actor name, company,
  location, bio, follower counts) are explicitly not promised.
- Two ledgers mean two exhaustion vocabularies; `/status` publishes both so a denial is
  attributable.

The measured-catch-up honesty rule. Capacity arithmetic is a hypothesis and is
labeled as one. The acceptance gate is measured: `/status` publishes arrivals,
completions, backlog delta, and a tri-state `catch_up.state`
(`keeping_up | not_keeping_up | insufficient_sample`, gated by
`CATCH_UP_MIN_SAMPLE_SECONDS`). When completions do not exceed arrivals the service
reports `not_keeping_up`; it never claims eventual catch-up, and it publishes no drain
ETA. Any documentation stating otherwise fails plan §16's forbidden-claims gate.

## Rejected alternatives

- Keep per-entity core enrichment and tune it. No tuning escapes the arithmetic: 40
  core attempts per hour cannot meet a demand sample fifty times larger, and raising the
  core enrichment slice can only cannibalize polling or the reserve.
- Authenticate. Out of scope by the issue and plan §2, and it would change the
  problem rather than solve it: an authenticated budget is larger, not unbounded, and
  the durability and honesty requirements are identical.
- Drop or sample work under pressure. Rejected by Appendix F already; quota is a
  scheduling constraint, not an entity outcome. This ADR extends that: even the new
  search denials (`ceiling`, `reserve`, `pacing`, `blocked`) only ever defer.
- `OR`-joined qualifiers or free-text search. The probe answered this: `OR`-joined
  exact qualifiers return 422, and free-text matching would reintroduce the
  wrong-entity risk that stable-ID validation exists to eliminate.
- Constructing detail URLs from identifiers after a search miss. Rejected on SSRF
  grounds: the boundary distinguishes application-origin constants from payload-origin
  URLs, and synthesizing URLs from data would blur the one line that keeps it auditable.
