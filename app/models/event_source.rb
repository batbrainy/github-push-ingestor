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

  validates :source_type, :status, presence: true
  validates :consecutive_failures, numericality: { greater_than_or_equal_to: 0 }
end
