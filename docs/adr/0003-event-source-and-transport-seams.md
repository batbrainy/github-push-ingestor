# 3. Event-source and transport seams, each with a shipped fixture implementation

Date: 2026-07-30

Status: Accepted

## Context

`IMPLEMENTATION_PLAN.md` §6 defines two seams: an **event source**, which isolates
endpoint construction and source-specific state, and a **transport**, which performs the
request. Appendix A item 7 upheld that design against a "this is speculative
abstraction" critique on one condition — both seams ship two implementations, so the
contract is exercised rather than imagined.

§12 adds three requirements that constrain how those implementations are built: fixture
mode must fail closed with no live fallback; one corpus must serve unit stubs,
integration tests, and the reviewer's Docker scenario; and VCR is rejected because
scripted conditional responses, changing rate-limit headers, and failure sequences have
to be authored rather than recorded.

§2A picks Faraday, whose ecosystem offers `faraday-retry` and
`faraday-follow_redirects` and whose Rails-default instinct is to use them.

## Decision

**The Faraday connection carries the adapter and nothing else.** Retries and redirects
are iterations of the full chain in `Github::RequestExecutor`, each acquiring the gate,
reserving budget, requesting, reconciling, and releasing.

**Nothing the caller supplied reaches the socket.** `Github::UrlPolicy` returns a frozen
`ValidatedUrl` rebuilt from the components that passed, with a constructor private to the
policy, and both transports accept only that type and only in their own mode.

**A `Github::Request` declares where its URL came from.** An `:application` origin — an
event source's own endpoint — is validated against the current mode directly. A
`:payload` origin — a payload URL, a `Link` target, a `Location` header — always clears
the full *live* policy first and is only then projected onto the fixture scheme.

**The corpus is manifest-indexed**, keyed by a canonical request key (path, then query
sorted by name), with body paths authored in the manifest and never derived from a URL.
A key's value is an ordered list whose last entry repeats forever; cursors live on the
transport instance. An unknown key raises.

**Every URL inside a corpus body is a real `https://api.github.com` URL.** The `fixture`
scheme is produced only by `FixtureEvents` and by the policy's post-validation
projection.

## Consequences

What this buys:

- Budget accounting stays true across retries and redirect hops. `faraday-retry` retries
  inside one connection call — beneath the request gate and beneath the ledger — so §10's
  "each attempt is a reservation" would silently become one debit per logical fetch, and
  the middleware would sleep its backoff while holding a session advisory lock.
- A redirect off `api.github.com` is impossible: `faraday-follow_redirects` follows
  `Location` without re-entering the SSRF boundary, and the executor's own loop
  re-validates every hop.
- The raw body survives for §7's retention and for PR 5's ability to tell "this body is
  not JSON" from "this event is malformed" — a JSON response middleware would erase both.
  `Response::RaiseError` is likewise absent, because 304, 403 and 404 are all statuses
  this application classifies rather than errors.
- A database written in fixture mode is indistinguishable from one written live, because
  what gets persisted is a real GitHub URL either way.
- The corpus is not addressable from a response body: a payload claiming a `fixture://`
  URL is refused as `scheme_not_allowed`, because payload URLs always clear the live
  policy first. Fixture mode is therefore never a weaker boundary than live.
- Path traversal is structurally impossible. `fixture://api.github.com/../../etc/passwd`
  parses with its path preserved, so a corpus that derived filenames from URLs would read
  it; here it is simply a miss, and the loader additionally proves every resolved path
  sits inside `bodies/`.
- One set of bytes drives both consumers, because the corpus's ordered-list semantics
  map exactly onto WebMock's multi-value `to_return`.
- Fixture mode still takes the gate, still reserves budget, and still reconciles the
  corpus's rate-limit headers. §12's "zero live quota consumed" means zero *GitHub*
  quota, not zero accounting — which is what makes the per-window bootstrap runnable
  entirely offline.

What it costs, stated plainly:

- More hand-written code than a middleware stack. A spec pins
  `connection.builder.handlers` empty so the decision cannot be reversed silently; adding
  `response :raise_error` alone fails three examples.
- The manifest is a second artifact that can drift from the bodies it names. Corpus
  integrity specs assert every cross-reference: every `actor.url`, `repo.url`, and `Link`
  target must resolve, every body must parse, and no body file may be orphaned.
- Positional response sequences mean a scenario's behaviour depends on call order.
  Conditional matching on `If-None-Match` was rejected as less deterministic; the
  assertion worth making — "the request carried the stored ETag" — is made against the
  fixture transport's recorded requests instead.
- Worst-case request count for one logical fetch is `(1 + MAX_REDIRECTS) × (1 +
  MAX_HTTP_RETRIES)` = 9 reservations. Bounded in practice by the ledger itself, which
  refuses once the class allowance is spent, and by the fact that `api.github.com` does
  not redirect the endpoints this application polls — redirects exist only for
  payload-supplied enrichment URLs.
- `Github::Transports::Faraday` shadows the `Faraday` gem constant inside its own
  namespace, so every gem reference in that file needs a leading `::`. §5 pins the class
  name, so the mitigation is the leading `::` plus a spec asserting the connection really
  is a `::Faraday::Connection`.
