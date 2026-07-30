# Polling and source-specific state. The scheduling constraints are four independent
# columns rather than one collapsed timestamp, so --force can bypass exactly one of
# them (cadence_due_at) while remaining bound by the server floor, source backoff, and
# the global block (§7, §9).
#
# No status vocabulary or CHECK constraint is defined here: PR 6 owns the poll state
# machine. Note that a rate-limited source is expressed by retry_not_before_at plus
# the global ledger, never by per-source rate-limit state — V2 moved that to
# github_api_budget (§7).
class EventSource < ApplicationRecord
  has_many :ingestion_runs, inverse_of: :event_source, dependent: :restrict_with_error

  validates :source_type, :status, presence: true
  validates :consecutive_failures, numericality: { greater_than_or_equal_to: 0 }
end
