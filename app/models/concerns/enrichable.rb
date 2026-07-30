# Actors and repositories share an identical entity-level enrichment state machine
# (IMPLEMENTATION_PLAN.md §7). This concern carries the *data* half — the value set, the
# enum, and the scope whose WHERE clause matches the partial index — plus the one
# transition that belongs to the ingest path rather than to enrichment: §7 merge rule 3's
# skipped_budget reactivation.
#
# Every other transition is a fetch outcome and lives in Github::Enrichment::EntityState,
# Github::Enrichment::AgeOut, or Github::Enrichment::Claim, all of which are constructed
# without an executor or a transport so a GitHub request cannot be issued from them.
#
# Two column conventions this state machine relies on, stated here because both invite
# the other reading:
#
#   * enrichment_attempts counts attempts **since the last success**, not for the
#     lifetime of the row. It is reset to zero on `complete`, following
#     Github::Ingestion::PollState's consecutive_failures. Its only two consumers — the
#     backoff exponent and the log line — both want that number.
#   * next_retry_at means one thing everywhere: *this entity may not be attempted before
#     T*. It is simultaneously the failure backoff, a secondary-limit deferral, and the
#     in-flight claim lease. One meaning is what lets a single predicate exclude
#     in-flight rows from the candidate pools and from the age-out sweep at once.
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

    # Guards upsert_stub!, which otherwise reaches PostgreSQL directly and turns a
    # malformed envelope into a NotNullViolation that aborts the ingest transaction
    # before the caller can route the event to quarantine.
    validates :github_id, presence: true

    scope :enrichment_candidates, -> { where(enrichment_status: CANDIDATE_STATUSES) }
  end

  class_methods do
    # The activity half of §7 merge rule 3. Its gate — calling this only when the
    # push_events insert actually returned a row, so a duplicate replay cannot register
    # activity — belongs to the ingest transaction in PR 5, and it is the same gate
    # .reactivate_skipped! sits behind.
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

    # The reactivation half of §7 merge rule 3, and §7's reactivation rule: "skipped_budget
    # is terminal for the entity's current eligibility window, not forever. A **newly
    # persisted** push event referencing the entity … may transition it back to pending."
    #
    # Rule 4 — "a duplicate event replay … can never reactivate enrichment" — is held by
    # the *call site*, not by a check here: PR 5 already calls this only when
    # PushEvent.insert_if_new returned a row. That is what makes the guarantee structural.
    #
    # A second statement rather than a CASE folded into .touch_activity!, for one reason
    # worth the extra write: §11 lists "reactivated" among the INFO events, and a
    # set-based UPDATE that also touched non-skipped rows could not report how many rows
    # it actually reactivated. This one's row count is exactly that number. It matches at
    # most one row, only on a genuinely new event, and almost always zero.
    #
    # No "missing or stale" sub-predicate is needed, because skipped_budget implies
    # missing enrichment. That is derived rather than assumed: the only writer of the
    # status is Github::Enrichment::AgeOut, whose WHERE is CANDIDATE_STATUSES, and no row
    # in those two statuses has ever completed — so fetched_at and raw_payload are NULL on
    # every one of them. A spec pins the invariant.
    #
    # It clears skipped_at and nothing else. enrichment_attempts and last_error are
    # records of *fetches*, and an inbound envelope is not a fetch — writing
    # last_error = NULL from a path that issued no request would assert something false.
    # next_retry_at is left because it is provably not blocking: AgeOut never skips a row
    # whose retry is in the future, so every skipped_budget row carries NULL or an instant
    # already past, and clearing it would only destroy history.
    #
    # @return [Integer] rows reactivated: 1 or 0.
    def reactivate_skipped!(github_id:, now:)
      where(github_id: github_id, enrichment_status: "skipped_budget")
        .update_all(enrichment_status: "pending", skipped_at: nil, updated_at: now)
    end
  end
end
