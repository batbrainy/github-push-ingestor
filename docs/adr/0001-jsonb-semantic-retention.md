# 1. Raw payload retention is semantic, not byte-exact

Date: 2026-07-29

Status: Accepted

## Context

The assignment requires the raw GitHub event payload to be retained alongside the
extracted structured fields, so an operator can audit or debug what was actually
received. `IMPLEMENTATION_PLAN.md` §7 stores it in `push_events.raw_payload` (and
`quarantined_events.raw_payload`) as PostgreSQL `jsonb`.

`jsonb` is a parsed, decomposed binary representation. It deliberately does not
preserve:

- insignificant whitespace,
- object key order,
- duplicate object keys (the last value wins).

So the bytes read back are not necessarily the bytes GitHub sent. Array element order
*is* preserved, because it is semantically meaningful.

The alternative is a `text` or `json` column holding the response body verbatim.

## Decision

Retain the payload as `jsonb` and treat retention as semantic: the stored document
is content-equivalent to what GitHub sent, not byte-identical to it.

## Consequences

What this buys:

- The payload is queryable and indexable in place. Should a demonstrated query need
  it, a GIN index can be added without a data migration (§7 gates that index on a
  real query rather than adding it speculatively).
- Malformed-payload comparison works on structure rather than formatting, which is
  what the quarantine fingerprint already relies on. The canonical fingerprint is
  computed over compact JSON with recursively sorted keys, so it is deliberately
  insensitive to exactly the things `jsonb` discards.
- Storage is smaller and reads need no parse step.

What it costs, stated plainly:

- This is not a byte-exact audit trail. A reviewer comparing stored bytes against
  a captured HTTP response will see differences in whitespace and key order.
- A payload containing duplicate keys is retained with only the last occurrence. No
  observed GitHub payload does this, but the loss would be silent.

Byte-exact retention would require a second `text` column holding the raw body, which
doubles payload storage to serve an audit requirement this project does not have. It
is deliberately not built. If a future requirement demands provable byte fidelity, add
the `text` column beside the `jsonb` one rather than converting: the query surface
depends on `jsonb`.

Tests assert content equivalence rather than byte equality, and one test asserts the
byte difference explicitly, so the tradeoff is visible in the suite instead of being
folklore.
