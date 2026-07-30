require "rails_helper"

RSpec.describe Github::Events::Outcome do
  describe "the three terminal states of §7's taxonomy" do
    it "describes a normalized push event" do
      outcome = described_class.push_event(
        event_type: "PushEvent", github_event_id: "1", raw_payload: { "id" => "1" },
        occurred_at: frozen_time, push_event_attributes: { ref: "refs/heads/main" },
        actor_attributes: { github_id: 1 }, repository_attributes: { github_id: 2 }
      )

      expect(outcome).to be_push_event
      expect(outcome).not_to be_ignored
      expect(outcome).not_to be_quarantined
      expect(outcome.error_code).to be_nil
    end

    it "describes an ignored event, which carries no error and no fingerprint" do
      outcome = described_class.ignored(event_type: "WatchEvent", github_event_id: "1",
                                       raw_payload: { "id" => "1" })

      expect(outcome).to be_ignored
      expect(outcome.error_code).to be_nil
      expect(outcome.payload_fingerprint).to be_nil
      expect(outcome.push_event_attributes).to be_nil
    end

    it "describes a quarantined event" do
      outcome = described_class.quarantined(
        event_type: nil, github_event_id: nil, raw_payload: nil,
        error_code: "invalid_envelope", error_message: "event is NilClass",
        payload_fingerprint: "0" * 64
      )

      expect(outcome).to be_quarantined
      expect(outcome.error_code).to eq("invalid_envelope")
    end

    it "refuses a kind outside the vocabulary, so a typo cannot become a dropped event" do
      expect { described_class.new(kind: :maybe) }
        .to raise_error(ArgumentError, /kind must be one of/)
    end
  end

  describe "#to_log" do
    it "carries the fields §11 asks for and omits the ones a kind does not have" do
      outcome = described_class.ignored(event_type: "WatchEvent", github_event_id: "58000000004",
                                       raw_payload: {})

      expect(outcome.to_log).to eq(github_event_id: "58000000004", event_type: "WatchEvent")
    end

    it "never puts the payload in a log line" do
      outcome = described_class.quarantined(
        event_type: "PushEvent", github_event_id: "1", raw_payload: { "secret" => "value" },
        error_code: "missing_required_field", error_message: "payload is missing head",
        payload_fingerprint: "0" * 64
      )

      expect(outcome.to_log).not_to include(:raw_payload)
    end
  end
end
