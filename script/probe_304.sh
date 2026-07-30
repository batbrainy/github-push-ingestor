#!/usr/bin/env bash
#
# Re-runs the unauthenticated 304 quota probe that IMPLEMENTATION_PLAN.md §10 makes a
# required validation gate for PR 6, and prints a paste-ready, pre-redacted transcript body
# for docs/evidence/.
#
# WHY THIS EXISTS
#
#   GitHub's events documentation states generally that 304 responses do not count against
#   the rate limit. Its REST best-practices documentation scopes that exemption to requests
#   "correctly authorized with an Authorization header". This service sends no token, so
#   the two statements disagree about exactly the population of requests it makes. §10
#   settles it with dated first-party evidence rather than by picking a doc to believe.
#
# WHY IT IS A SHELL SCRIPT AND NOT A RAKE TASK
#
#   A rake task loads Rails, which would put a live network probe one autoload away from
#   Github.executor and the developer's github_api_budget row — it would debit and
#   reconcile the very ledger the transcript is about. This process knows nothing about the
#   application. It is also not in bin/, which holds what the product runs: bin/ingest is
#   what `docker compose run --rm ingest` resolves to, and an evidence-gathering tool there
#   invites someone to wire it into compose or CI.
#
# COST: three requests from this machine's public IP, out of the sixty an hour that IP
# gets. Run it before any live demo in the same hour, not after.
#
# Nothing in the repository executes this file. spec/network_boundary_spec.rb asserts that,
# so "CI never runs the probe" is a red test rather than a promise.

set -euo pipefail

readonly URL="https://api.github.com/events?per_page=100"
readonly ACCEPT="application/vnd.github+json"
readonly API_VERSION="2022-11-28"
# Byte-identical to Github::Request::PROTOCOL_HEADERS, so the transcript is evidence about
# the requests this application actually makes rather than about a differently-identified
# client. It also avoids the usual probe convention of putting a name or an email in the
# User-Agent, which would be committed PII.
readonly USER_AGENT="github-push-ingestor"

if [ -n "${CI:-}" ]; then
  echo "refusing: this probe makes live requests to api.github.com" >&2
  exit 2
fi

if [ "${1:-}" != "--confirm" ]; then
  cat >&2 <<'USAGE'
usage: script/probe_304.sh --confirm

Makes three live, unauthenticated GET requests to api.github.com and prints a transcript
body for docs/evidence/. Spends 3 of this IP's 60 requests per hour.

  R1  GET, no If-None-Match      -> 200, ETag, x-ratelimit-used = U
  R2  GET, If-None-Match: <ETag> -> 304, used = U+1   <- the finding
  R3  GET, If-None-Match: <ETag> -> 304, used = U+2   <- the control

No Authorization header is sent, and no response body is written anywhere.
USAGE
  exit 2
fi

# Redaction is mechanical rather than a human remembering. x-github-request-id is not
# secret and cannot be replayed to authenticate anything, but it is a durable server-side
# handle tying a specific request to a specific client in GitHub's own logs, and no reader
# outside GitHub can resolve it — so it costs nothing to remove and the finding does not
# depend on it. The header name is kept and the value replaced, never the whole line
# deleted: a curated dump that looks complete is worse than one that shows what was taken
# out.
redact() {
  sed -E 's/^(x-github-request-id|set-cookie|x-runtime-rid):.*/\1: <redacted>/I'
}

# -D - dumps headers, never -v, which would print TLS and connection detail that has to be
# stripped afterwards. -o /dev/null on all three: the /events body is ~90 real events with
# real logins, avatar URLs embedding numeric user IDs, and repository names — third-party
# personal data that the finding does not need and that must not be committed. GET, never
# -I, because §10 requires a normal GET.
# Exactly one request per call, and the caller keeps the dump — re-fetching to read the
# ETag back out would spend a fourth request and quietly weaken the arithmetic the whole
# transcript rests on.
#
# Extra headers ride in on "$@" rather than in an array. macOS ships bash 3.2, where
# expanding an empty array under `set -u` is an unbound-variable error — so the obvious
# `"${conditional[@]}"` aborts the probe on the very machine most likely to run it.
# Positional parameters are special-cased and safe when empty.
request() {
  curl --silent --show-error -o /dev/null -D - \
    -H "Accept: ${ACCEPT}" \
    -H "X-GitHub-Api-Version: ${API_VERSION}" \
    -H "User-Agent: ${USER_AGENT}" \
    "$@" \
    "$URL" | tr -d '\r'
}

fetch() {
  local etag="${1:-}"

  if [ -n "$etag" ]; then
    request -H "If-None-Match: ${etag}"
  else
    request
  fi
}

etag_from() {
  printf '%s\n' "$1" | awk 'tolower($1) == "etag:" { $1 = ""; sub(/^ /, ""); print; exit }'
}

report() {
  local label="$1" sent_at="$2" etag="${3:-}" dump="$4"

  echo "### ${label}"
  echo
  echo "Local clock (UTC): ${sent_at}"
  echo
  echo '```http'
  echo "GET /events?per_page=100 HTTP/2"
  echo "Host: api.github.com"
  echo "Accept: ${ACCEPT}"
  echo "X-GitHub-Api-Version: ${API_VERSION}"
  echo "User-Agent: ${USER_AGENT}"
  [ -n "$etag" ] && echo "If-None-Match: ${etag}"
  echo
  printf '%s\n' "$dump" | redact
  echo '```'
  echo
}

echo "## Raw response headers"
echo
echo "Redacted in place, name kept: \`x-github-request-id\`, \`set-cookie\`, \`x-runtime-rid\`."
echo "No response body was captured. No \`Authorization\` header was sent."
echo

# The request headers are echoed alongside each response for a reason: a response dump on
# its own cannot prove that no Authorization header was sent, or that the API version was
# explicit, and both are load-bearing for the finding.
SENT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
R1="$(fetch)"
report "R1 — unconditional GET" "$SENT_AT" "" "$R1"

ETAG="$(etag_from "$R1")"
if [ -z "$ETAG" ]; then
  echo "aborting: no ETag in the R1 response, so there is nothing to replay conditionally" >&2
  exit 1
fi

sleep 2
SENT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
R2="$(fetch "$ETAG")"
report "R2 — conditional GET (the finding)" "$SENT_AT" "$ETAG" "$R2"

sleep 2
SENT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
R3="$(fetch "$ETAG")"
report "R3 — conditional GET again (the control)" "$SENT_AT" "$ETAG" "$R3"

cat <<'NOTE'
Now fill in the comparison table at the top of the transcript from the `date`,
`x-ratelimit-used`, `x-ratelimit-remaining` and `etag` values above, and check that
`x-ratelimit-resource` reads `core` on every response — that is the bucket
Github::BudgetLedger reconciles against.
NOTE
