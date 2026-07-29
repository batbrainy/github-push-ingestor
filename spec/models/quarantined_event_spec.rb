require "rails_helper"

RSpec.describe QuarantinedEvent do
  let(:fingerprint) { "a" * 64 }

  describe ".record!" do
    it "stores a malformed payload with its classification" do
      id = described_class.record!(
        payload_fingerprint: fingerprint,
        raw_payload: { "type" => "PushEvent" },
        github_event_id: "40000000001",
        event_type: "PushEvent",
        error_code: "missing_required_field",
        error_message: "payload.push_id is absent",
        received_at: frozen_time
      )

      event = described_class.find(id)
      expect(event.payload_fingerprint).to eq(fingerprint)
      expect(event.error_code).to eq("missing_required_field")
      expect(event.occurrence_count).to eq(1)
      expect(event.first_received_at).to eq(frozen_time)
      expect(event.last_received_at).to eq(frozen_time)
    end

    it "counts a repeat of the same payload instead of inserting a second row" do
      described_class.record!(payload_fingerprint: fingerprint,
                              raw_payload: { "type" => "PushEvent" },
                              received_at: frozen_time)
      described_class.record!(payload_fingerprint: fingerprint,
                              raw_payload: { "type" => "PushEvent" },
                              received_at: frozen_time + 300)

      event = described_class.sole
      expect(event.occurrence_count).to eq(2)
      expect(event.first_received_at).to eq(frozen_time)
      expect(event.last_received_at).to eq(frozen_time + 300)
    end

    it "retains the first classification of a payload across repeats" do
      described_class.record!(payload_fingerprint: fingerprint,
                              raw_payload: { "type" => "PushEvent" },
                              error_code: "missing_required_field",
                              received_at: frozen_time)
      described_class.record!(payload_fingerprint: fingerprint,
                              raw_payload: { "type" => "PushEvent" },
                              error_code: "something_else",
                              received_at: frozen_time + 300)

      expect(described_class.sole.error_code).to eq("missing_required_field")
    end

    it "never regresses last_received_at for a late-arriving repeat" do
      described_class.record!(payload_fingerprint: fingerprint,
                              raw_payload: { "type" => "PushEvent" },
                              received_at: frozen_time + 300)
      described_class.record!(payload_fingerprint: fingerprint,
                              raw_payload: { "type" => "PushEvent" },
                              received_at: frozen_time)

      event = described_class.sole
      expect(event.last_received_at).to eq(frozen_time + 300)
      expect(event.occurrence_count).to eq(2)
    end

    # Plan §7: a malformed event may be malformed precisely because it lacks an event
    # ID, so the fingerprint is the sole identity.
    it "accepts a payload with no event id at all" do
      id = described_class.record!(payload_fingerprint: fingerprint,
                                   raw_payload: { "malformed" => true },
                                   received_at: frozen_time)

      expect(described_class.find(id).github_event_id).to be_nil
    end

    it "keeps the same event id with different payloads as separate rows" do
      described_class.record!(payload_fingerprint: "a" * 64,
                              raw_payload: { "variant" => 1 },
                              github_event_id: "40000000001",
                              received_at: frozen_time)
      described_class.record!(payload_fingerprint: "b" * 64,
                              raw_payload: { "variant" => 2 },
                              github_event_id: "40000000001",
                              received_at: frozen_time)

      expect(described_class.where(github_event_id: "40000000001").count).to eq(2)
      expect(described_class.pluck(:occurrence_count)).to eq([ 1, 1 ])
    end
  end

  describe "database constraints" do
    it "makes the fingerprint the sole unique identity" do
      described_class.record!(payload_fingerprint: fingerprint,
                              raw_payload: { "type" => "PushEvent" },
                              received_at: frozen_time)

      expect_violation(ActiveRecord::RecordNotUnique) do
        described_class.insert!(quarantined_event_attributes(payload_fingerprint: fingerprint))
      end
    end

    it "does not constrain github_event_id to be unique" do
      index = described_class.connection.indexes(:quarantined_events)
                             .find { |i| i.columns == [ "github_event_id" ] }

      expect(index).not_to be_nil
      expect(index.unique).to be(false)
    end

    it "requires a fingerprint, a payload, and both receipt timestamps" do
      %i[payload_fingerprint raw_payload first_received_at last_received_at].each do |column|
        expect_violation(ActiveRecord::NotNullViolation) do
          described_class.insert!(quarantined_event_attributes.except(column))
        end
      end
    end

    it "rejects an occurrence count below one" do
      expect_violation(ActiveRecord::CheckViolation) do
        described_class.insert!(quarantined_event_attributes(occurrence_count: 0))
      end
    end
  end
end
