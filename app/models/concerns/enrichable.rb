# Actors and repositories share an identical entity-level enrichment state machine
# (IMPLEMENTATION_PLAN.md §7). This concern carries only the *data* half: the value
# set, the enum, and the scope whose WHERE clause matches the partial index.
#
# The transitions themselves — TTL staleness, budget skips, and skipped_budget
# reactivation — are PR 7 (plan §13). Nothing here changes enrichment_status.
module Enrichable
  extend ActiveSupport::Concern

  ENRICHMENT_STATUSES = %w[
    pending
    complete
    retryable_failure
    permanent_failure
    skipped_budget
  ].freeze

  # Exactly the predicate of index_*_on_enrichment_candidates.
  CANDIDATE_STATUSES = %w[pending retryable_failure].freeze

  included do
    enum :enrichment_status, ENRICHMENT_STATUSES.index_by(&:itself), validate: true

    scope :enrichment_candidates, -> { where(enrichment_status: CANDIDATE_STATUSES) }
  end

  class_methods do
    # The *effect* of §7 merge rule 3. Its gate — calling this only when the
    # push_events insert actually returned a row, so a duplicate replay cannot
    # register activity — belongs to the ingest transaction in PR 5.
    #
    # Every timestamp is monotonic, so a delayed or out-of-order observation can
    # never move one backwards and distort newest-first enrichment ordering.
    # PostgreSQL's GREATEST/LEAST ignore NULL arguments, returning NULL only when
    # every argument is NULL, so no COALESCE is required for the first write.
    def touch_activity!(github_id:, seen_at:, event_occurred_at:)
      assignments = sanitize_sql_array([
        "first_seen_at = LEAST(first_seen_at, :seen_at), " \
        "last_seen_at = GREATEST(last_seen_at, :seen_at), " \
        "latest_event_at = GREATEST(latest_event_at, :occurred), " \
        "updated_at = GREATEST(updated_at, :seen_at)",
        { seen_at: seen_at, occurred: event_occurred_at }
      ])

      where(github_id: github_id).update_all(assignments)
    end
  end
end
