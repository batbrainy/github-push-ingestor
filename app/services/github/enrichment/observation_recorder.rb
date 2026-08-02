module Github
  module Enrichment
    class ObservationRecorder
      def self.record!(entity_type:, entity_github_id:, source:, raw_payload:, observed_at:,
                       validation_outcome:, batch: nil, push_event: nil,
                       requested_identifier: nil, correlation_id: nil)
        EnrichmentObservation.create!(
          entity_kind: entity_type.key.to_s,
          entity_github_id: entity_github_id,
          source: source.to_s,
          observed_at: observed_at,
          raw_payload: raw_payload,
          payload_fingerprint: Events::PayloadFingerprint.fingerprint(raw_payload),
          enrichment_batch: batch,
          push_event: push_event,
          request_correlation_id: correlation_id || batch&.correlation_id,
          requested_identifier: requested_identifier,
          validation_outcome: validation_outcome
        )
      end
    end
  end
end
