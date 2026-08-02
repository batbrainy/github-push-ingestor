class EnrichmentObservation < ApplicationRecord
  SOURCES = %w[event search detail].freeze
  ENTITY_KINDS = %w[actor repository].freeze

  belongs_to :enrichment_batch, optional: true
  belongs_to :push_event, optional: true

  validates :entity_kind, inclusion: { in: ENTITY_KINDS }
  validates :source, inclusion: { in: SOURCES }
  validates :observed_at, :raw_payload, :payload_fingerprint, :validation_outcome,
            presence: true

  scope :during, ->(range) { where(observed_at: range) }

  # Audit evidence is append-only. Batch envelopes are updated as their request finishes;
  # individual observations never are.
  def readonly?
    persisted?
  end
end
