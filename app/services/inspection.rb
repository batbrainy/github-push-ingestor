# IMPLEMENTATION_PLAN.md §11's event inspection API.
#
# The two limits every parameter destined for the database has to respect. They are
# properties of PostgreSQL's column types, not policy, which is why they are constants here
# rather than configuration — and why they are stated once for the two parsers that need
# them (Inspection::PushEventPage validates query parameters, Inspection::Cursor validates
# a position a client hands back).
#
# Both were verified against PostgreSQL 16 rather than taken from documentation, because
# the two paths fail *differently* and only one of them fails loudly:
#
#   * A raw bind — the seek predicate's `push_events.id < :id` — raises
#     ActiveRecord::RangeError (PG::NumericValueOutOfRange) one past BIGINT_MAX, which
#     would surface as a 500.
#   * A typed-column bind — `where(github_actor_id: …)` — does **not** raise. Active
#     Record casts the out-of-range value and the query returns normally, so an id no row
#     could ever hold produces a silent empty page that is indistinguishable from a
#     genuine miss.
#
# The second is the reason these are checked in the parsers rather than left to the
# database: refusing the value up front is the only way both paths give the client the
# documented 400 instead of a 500 in one case and a plausible lie in the other.
module Inspection
  # PostgreSQL bigint, which is the type of push_events.id, github_actor_id and
  # github_repository_id. Verified: 2**63 - 1 binds cleanly and 2**63 raises.
  BIGINT_MAX = 2**63 - 1

  # PostgreSQL's timestamp ceiling. Verified: year 294276 binds cleanly and 294277 raises
  # PG::DatetimeFieldOverflow. Ruby's Time.iso8601 happily parses years far beyond it, so
  # a forged cursor reaches the database unless something between them says no.
  MAX_TIMESTAMP_YEAR = 294_276
end
