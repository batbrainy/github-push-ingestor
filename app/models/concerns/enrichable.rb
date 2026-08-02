# Actors and repositories share an identical entity-level enrichment state machine
# (IMPLEMENTATION_PLAN.md §7). This concern carries the *data* half — the value set, the
# enum, and the scope whose WHERE clause matches the partial index.
#
# Every other transition is a fetch outcome and lives in the batch and detail runners,
# which reach the entity rows through Github::Enrichment::BatchClaim and
# Github::Enrichment::DetailClaim — neither claim holds an executor or a transport, so a
# GitHub request cannot be issued from them.
#
# Two columns carry the *business* outcome and the *pipeline position* separately, and the
# split is load-bearing (plan Appendix G): enrichment_status is what an operator reports
# on, enrichment_stage is where the row sits in the staged pipeline. Legal pairs:
#
#   pending            → batch_pending, batch_in_flight, detail_pending,
#                        detail_in_flight, retry_scheduled
#   retryable_failure  → retry_scheduled, batch_in_flight, detail_pending, detail_in_flight
#   complete           → contract_complete, and the in-flight/pending stages during a refresh
#   permanent_failure  → terminal
#
# Three column conventions this state machine relies on, stated here because each invites
# the other reading:
#
#   * enrichment_attempts counts attempts **since the last success**, not for the
#     lifetime of the row. It is reset to zero on `complete`, following
#     Github::Ingestion::PollState's consecutive_failures. Its only two consumers — the
#     backoff exponent and the log line — both want that number.
#   * next_retry_at means one thing everywhere: *this entity may not be attempted before
#     T*. It is both the failure backoff and a secondary-limit deferral. It is no longer
#     the claim lease — leases are explicit now (lease_token, leased_until), so a retry
#     instant and a live claim can no longer be mistaken for each other.
#   * detail_attempts counts only fallback fetches, so the bounded core allowance's
#     ladder is independent of how many times the Search lane batched the row.
module Enrichable
  extend ActiveSupport::Concern

  # Resting pipeline positions only. Event-native persistence, local derivation,
  # and batch application are instants (event_native_at / derived_at /
  # batch_applied_at); a row never rests in them, so they are not stages.
  ENRICHMENT_STAGES = %w[
    batch_pending
    batch_in_flight
    detail_pending
    detail_in_flight
    retry_scheduled
    contract_complete
    terminal
  ].freeze

  ENRICHMENT_STATUSES = %w[
    pending
    complete
    retryable_failure
    permanent_failure
  ].freeze

  # Exactly the predicate of index_*_on_enrichment_candidates.
  CANDIDATE_STATUSES = %w[pending retryable_failure].freeze

  included do
    enum :enrichment_status, ENRICHMENT_STATUSES.index_by(&:itself), validate: true
    enum :enrichment_stage, ENRICHMENT_STAGES.index_by(&:itself), validate: true,
                              prefix: :stage

    # Guards upsert_stub!, which otherwise reaches PostgreSQL directly and turns a
    # malformed envelope into a NotNullViolation that aborts the ingest transaction
    # before the caller can route the event to quarantine.
    validates :github_id, presence: true

    scope :enrichment_candidates, -> { where(enrichment_status: CANDIDATE_STATUSES) }
    scope :durable_enrichment_backlog, -> { where.not(enrichment_stage: %w[contract_complete terminal]) }

    belongs_to :latest_observation, class_name: "EnrichmentObservation", optional: true
    belongs_to :current_enrichment_batch, class_name: "EnrichmentBatch", optional: true
  end

  class_methods do
    # The activity half of §7 merge rule 3. Its gate — calling this only when the
    # push_events insert actually returned a row, so a duplicate replay cannot register
    # activity — belongs to the ingest transaction in PR 5.
    #
    # Every timestamp is monotonic, so a delayed or out-of-order observation can never
    # move activity history backwards. FIFO enrichment itself uses immutable created_at.
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
