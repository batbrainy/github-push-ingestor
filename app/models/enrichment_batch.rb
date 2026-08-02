class EnrichmentBatch < ApplicationRecord
  REQUEST_KINDS = %w[search detail].freeze
  ENTITY_KINDS = %w[actor repository].freeze
  STATUSES = %w[in_flight succeeded failed deferred stale_lease].freeze

  has_many :enrichment_observations, dependent: :restrict_with_error

  # The column's default is the server-side gen_random_uuid(), which Active Record
  # cannot evaluate before validation — so a create! that relied on it would fail the
  # presence validation below rather than reach the INSERT. Assigned here so the
  # correlation id exists client-side, where the observations written alongside this
  # batch need it anyway.
  before_validation { self.correlation_id ||= SecureRandom.uuid }

  validates :request_kind, inclusion: { in: REQUEST_KINDS }
  validates :entity_kind, inclusion: { in: ENTITY_KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :correlation_id, presence: true, uniqueness: true
  validates :started_at, presence: true
  validates :requested_count, :returned_count, :valid_count, :missing_count, :invalid_count,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :during, ->(range) { where(started_at: range) }
end
