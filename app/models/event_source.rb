# Polling and source-specific state. The scheduling constraints are four independent
# columns rather than one collapsed timestamp, so --force can bypass exactly one of
# them (cadence_due_at) while remaining bound by the server floor, source backoff, and
# the global block (§7, §9). Github::PollSchedule is what reads them; nothing here
# decides when a poll may happen, because that answer also depends on the global ledger
# and this model deliberately carries no budget state.
#
# The status vocabulary is two values and stops there. Everything else a poll state
# machine is tempted to record already exists: whether a poll is in flight is the source
# advisory lock's answer (and crash-safe, which a status column is not), when the next
# one is due is effective_poll_time's, and how badly a source is failing is
# consecutive_failures'. A rate-limited source is expressed by retry_not_before_at plus
# the global ledger, never by per-source rate-limit state — V2 moved that to
# github_api_budget (§7).
class EventSource < ApplicationRecord
  # idle   — healthy and schedulable. A completed poll, a 304, and every deferral leave
  #          it here; a deferral is a fact about time, not about the source's health.
  # failed — §10's "/events returns permanent 4xx → source failed". Enforced rather than
  #          merely recorded: Github::IngestionRunner refuses to poll a failed source at
  #          all, including under --force, because the request cannot succeed and polling
  #          it on a cadence would spend the hourly budget on a certainty.
  #          Operator-recoverable only — nothing writes this back to idle, since a later
  #          success cannot happen and inventing an automatic transition would silently
  #          return a source to service without anyone looking at why it left.
  STATUSES = %w[idle failed].freeze

  has_many :ingestion_runs, inverse_of: :event_source, dependent: :restrict_with_error

  enum :status, STATUSES.index_by(&:itself), validate: true

  # PR 8's recurring tick asks this before it asks anything else, and it is a **pre-filter,
  # never the decision**. Github::PollSchedule reading the four components under the source
  # lock stays the authority — Github::IngestionRunner reloads the row inside the lock
  # precisely so a decision is made against committed state.
  #
  # Filtering on next_poll_at is safe because that column can only be conservative. It is a
  # projection written at the end of each run from values that had already been committed,
  # and §9's components only ever move later or are cleared by the run that clears them —
  # so a row this scope skips was genuinely not due, and no source can be stranded by it.
  # The cost of being wrong in the other direction is nil: the runner re-checks and returns
  # `deferred` without opening a run row.
  #
  # source_type is not a nicety. A development database routinely holds two rows — the
  # README's reviewer path creates a github_fixture_events source with
  # `GITHUB_MODE=fixture docker compose run --rm ingest` — and a live worker polling the
  # fixture row (or the reverse) would either be refused by Github::UrlPolicy or raise
  # Errors::FixtureMiss, once a minute, forever.
  #
  # enabled/status are excluded here rather than left to the runner because
  # IngestionRunner#out_of_service warns on every attempt: a failed source is
  # operator-recoverable only, so the tick would emit a warning a minute until someone
  # looked, burying the lines §11 asks reviewers to read.
  scope :poll_due, ->(source_type:, now:) {
    where(source_type: source_type, enabled: true, status: "idle")
      .where("next_poll_at IS NULL OR next_poll_at <= :now", now: now)
      .order(:id)
  }

  validates :source_type, :status, presence: true
  validates :consecutive_failures, numericality: { greater_than_or_equal_to: 0 }
end
