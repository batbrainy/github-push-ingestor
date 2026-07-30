class QuarantinedEvent < ApplicationRecord
  # raw_payload is deliberately absent from this list. An invalid envelope may itself be
  # `null`, `{}`, or `[]`, and `presence` rejects all three as blank — which would refuse
  # to quarantine exactly the events §7's taxonomy says must be quarantined.
  validates :payload_fingerprint, :first_received_at, :last_received_at, presence: true
  validates :occurrence_count, numericality: { greater_than_or_equal_to: 1 }

  # §7's occurrence-count upsert. error_code and error_message are deliberately not
  # refreshed on replay — the plan pins the SET clause to last_received_at and
  # occurrence_count, so the first classification of a payload is the one retained.
  #
  # Both timestamps use GREATEST rather than a plain assignment: a delayed or
  # clock-skewed replay must not move either backwards. For last_received_at that would
  # contradict its stated meaning ("most recent observation"); for updated_at a row's
  # modification time must never regress. This is a deliberate hardening of the plan's
  # snippet, not a change of intent.
  OCCURRENCE_MERGE = <<~SQL.squish
    last_received_at = GREATEST(quarantined_events.last_received_at,
                                EXCLUDED.last_received_at),
    occurrence_count = quarantined_events.occurrence_count + 1,
    updated_at       = GREATEST(quarantined_events.updated_at, EXCLUDED.updated_at)
  SQL

  # payload_fingerprint is supplied by the caller. Computing it — SHA-256 of compact
  # UTF-8 JSON with recursively sorted object keys — is PR 5.
  def self.record!(payload_fingerprint:, raw_payload:, github_event_id: nil,
                   event_type: nil, error_code: nil, error_message: nil,
                   received_at: Time.current)
    upsert(
      {
        payload_fingerprint: payload_fingerprint,
        raw_payload: raw_payload,
        github_event_id: github_event_id,
        event_type: event_type,
        error_code: error_code,
        error_message: error_message,
        first_received_at: received_at,
        last_received_at: received_at,
        occurrence_count: 1,
        created_at: received_at,
        updated_at: received_at
      },
      unique_by: :payload_fingerprint,
      on_duplicate: Arel.sql(OCCURRENCE_MERGE),
      returning: %w[id]
    ).rows.dig(0, 0)
  end
end
