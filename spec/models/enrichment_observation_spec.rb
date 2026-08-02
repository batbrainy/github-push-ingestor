require "rails_helper"

RSpec.describe EnrichmentObservation do
  def create_observation(**overrides)
    described_class.create!({
      entity_kind: "actor", source: "event", observed_at: frozen_time,
      raw_payload: { "id" => 583_231, "login" => "octocat" },
      payload_fingerprint: "0" * 64, validation_outcome: "event_native",
      entity_github_id: 583_231
    }.merge(overrides))
  end

  describe "validations" do
    it "accepts each documented source and rejects an invented one" do
      described_class::SOURCES.each do |source|
        expect(create_observation(source: source)).to be_persisted
      end
      expect { create_observation(source: "webhook") }
        .to raise_error(ActiveRecord::RecordInvalid, /Source/)
    end

    it "accepts both entity kinds and rejects an invented one" do
      expect(create_observation(entity_kind: "repository")).to be_persisted
      expect { create_observation(entity_kind: "organization") }
        .to raise_error(ActiveRecord::RecordInvalid, /Entity kind/)
    end

    it "requires the audit fields evidence is useless without" do
      {
        observed_at: nil, raw_payload: nil, payload_fingerprint: nil, validation_outcome: nil
      }.each do |field, blank|
        expect { create_observation(field => blank) }
          .to raise_error(ActiveRecord::RecordInvalid), "expected #{field} to be required"
      end
    end

    # Both parents are optional on purpose: an event-sourced observation belongs to a
    # push event and no batch, a search-sourced one to a batch and no push event.
    it "persists without either parent" do
      expect(create_observation.enrichment_batch).to be_nil
      expect(create_observation(payload_fingerprint: "1" * 64).push_event).to be_nil
    end

    it "associates with the batch whose request produced it" do
      batch = EnrichmentBatch.create!(request_kind: "search", entity_kind: "actor",
                                      started_at: frozen_time,
                                      correlation_id: SecureRandom.uuid)

      expect(create_observation(enrichment_batch: batch).enrichment_batch_id).to eq(batch.id)
    end
  end

  # Audit evidence is append-only. Batch envelopes are updated as their request
  # finishes; individual observations never are — enforced by the model rather than
  # by convention, so no code path can rewrite history quietly.
  describe "the append-only contract" do
    it "refuses an update once persisted" do
      observation = create_observation

      expect { observation.update!(validation_outcome: "rewritten") }
        .to raise_error(ActiveRecord::ReadOnlyRecord)
      expect(observation.reload.validation_outcome).to eq("event_native")
    end

    it "refuses a destroy once persisted" do
      observation = create_observation

      expect { observation.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect(described_class.count).to eq(1)
    end

    it "is writable exactly once: the create itself" do
      expect(create_observation).to be_persisted
    end
  end

  describe "the retained payload" do
    # Content-equivalent, not byte-equal: jsonb normalizes key order and whitespace,
    # and hash equality is the contract the fingerprint is computed over.
    it "round-trips the raw payload as structured data" do
      observation = create_observation(raw_payload: { "login" => "octocat", "id" => 583_231 })

      expect(observation.reload.raw_payload).to eq("id" => 583_231, "login" => "octocat")
    end
  end

  describe ".during" do
    it "selects by the instant the payload was observed" do
      inside = create_observation(observed_at: frozen_time)
      create_observation(observed_at: frozen_time - 7200, payload_fingerprint: "2" * 64)

      expect(described_class.during((frozen_time - 3600)..frozen_time)).to eq([ inside ])
    end
  end
end
