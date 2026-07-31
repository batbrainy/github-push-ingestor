# 11. Pinned REST API version `2022-11-28`, with `2026-03-10` as a gated follow-up

Date: 2026-07-31

Status: Accepted

## Context

GitHub's REST API is versioned by a request header. `IMPLEMENTATION_PLAN.md` §2A pins
`X-GitHub-Api-Version: 2022-11-28` on every outbound request
(`app/services/github/request.rb:32-36`), and §14 asks for that pin to carry a record.

Two version facts, verified 2026-07-29 and recorded in the plan's Appendix B: `2022-11-28`
is the version GitHub applies when no header is sent, and is supported until 2028-03-10;
`2026-03-10` is the latest published version.

The pin is not inertia. Every quantitative claim this design rests on was measured under
`2022-11-28`:

- The unauthenticated `304` quota finding
  ([`docs/evidence/2026-07-30-unauthenticated-304-quota-probe.md`](../evidence/2026-07-30-unauthenticated-304-quota-probe.md)),
  which is why the budget ledger debits conditional requests (ADR 0004).
- The observed page composition — roughly 92–95 `PushEvent` records in one 100-event page —
  which produces §10's enrichment-demand arithmetic and therefore the fairness shares
  (ADR 0007).
- The payload field set the tolerant parser accepts, including 40- and 64-character object
  names in `payload.head` and `payload.before`.

Sending a newer version header would invalidate the evidence behind all three at once,
silently, with no failing test to catch it — the fixture corpus is a recording of
`2022-11-28` responses, so the offline suite would stay green while live behaviour drifted.

## Decision

Pin `2022-11-28` as a frozen constant in `Github::Request::PROTOCOL_HEADERS`, not an
environment variable.

The version is not configurable for the same reason the API host is not
(ADR 0003): it is a correctness parameter of the evidence this design cites, not a
deployment knob. An operator who could set it to `2026-03-10` from `.env` could invalidate
the budget arithmetic without changing a line of code or failing a test.

**Upgrading to `2026-03-10` is a deliberate follow-up, gated on re-verification rather than
on availability.** The gate, in order:

1. Re-run `script/probe_304.sh` under the new version and commit a dated transcript. If
   `x-ratelimit-used` no longer increments across an unauthenticated `304`, ADR 0004's
   debit rule changes and the allowance formula changes with it.
2. Re-capture a live `/events` page and diff its shape against the fixture corpus —
   specifically that `PushEvent` still carries `payload.push_id`, `payload.ref`,
   `payload.head`, `payload.before`, and that `actor`/`repo` still carry the `id`s the
   foreign keys target.
3. Re-measure the `PushEvent` fraction of a page. §10's arithmetic assumes ~92–95 of 100.
4. Re-record the corpus under the new version, then change the constant.

Only step 4 is a code change. Steps 1–3 are why the pin exists.

## Consequences

What this buys:

- Every number in `docs/DESIGN_BRIEF.md` and the README traces to a probe run under the
  version the code actually sends. The evidence and the implementation cannot disagree.
- The fixture corpus is a faithful recording rather than an approximation, which is what
  makes `GITHUB_MODE=fixture` a real second transport implementation rather than a mock.
- No operator can silently invalidate the rate-limit design through configuration.

What it costs, stated plainly:

- The system does not benefit from whatever `2026-03-10` improved. Nothing in this
  submission needs it, but that is an assertion about today's requirements, not a
  general one.
- The pin has an expiry. `2022-11-28` is supported until 2028-03-10; after that the
  upgrade is forced rather than chosen, and the four-step gate above has to run under time
  pressure instead of at leisure.
- Because the version lives in a frozen constant, upgrading requires a code change, a
  release, and a re-recorded corpus — deliberately more friction than editing `.env`.

The suite asserts the header rather than the version's effects, which is the honest
boundary: `spec/services/github/request_spec.rb:64` and
`spec/services/github/transports/faraday_spec.rb:36` prove every outbound request carries
`2022-11-28`, and `spec/support/shared_examples/github_transport.rb:55` holds both
transports to it. No offline test can prove GitHub's behaviour under any version — that is
what the dated probe transcripts are for.
