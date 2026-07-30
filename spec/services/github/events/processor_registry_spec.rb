require "rails_helper"

RSpec.describe Github::Events::ProcessorRegistry do
  subject(:registry) { described_class.default }

  describe "the registry" do
    # §6: "The event processor registry will initially support only PushEvent."
    it "implements exactly PushEvent" do
      expect(described_class.implemented_types).to eq([ "PushEvent" ])
    end

    it "is frozen, so a caller cannot register a processor at runtime" do
      expect(described_class.registry).to be_frozen
    end

    it "reports the types the instance was built with" do
      expect(registry.event_types).to eq([ "PushEvent" ])
      expect(registry).to be_handles("PushEvent")
      expect(registry).not_to be_handles("WatchEvent")
    end
  end

  # §6: "Configured event types must be validated against implemented processors.
  # Unsupported types should fail fast with a clear configuration error." Mirrors
  # Github::EventSources::Base.for, down to the message shape.
  describe ".for" do
    it "builds a registry for an implemented type" do
      expect(described_class.for(%w[PushEvent]).event_types).to eq([ "PushEvent" ])
    end

    it "accepts a single type rather than requiring an array" do
      expect(described_class.for("PushEvent").event_types).to eq([ "PushEvent" ])
    end

    it "refuses an unimplemented type and names what is implemented" do
      expect { described_class.for(%w[PushEvent IssuesEvent]) }
        .to raise_error(Github::Errors::ConfigurationError,
                        /no event processor implements IssuesEvent; implemented types: PushEvent/)
    end

    it "names every unimplemented type, not just the first" do
      expect { described_class.for(%w[IssuesEvent ForkEvent]) }
        .to raise_error(Github::Errors::ConfigurationError, /ForkEvent, IssuesEvent/)
    end

    it "refuses an empty configuration, which would silently process nothing" do
      expect { described_class.for([ "", "  " ]) }
        .to raise_error(Github::Errors::ConfigurationError, /no event types were configured/)
    end

    it "tolerates surrounding whitespace and a repeated type" do
      expect(described_class.for([ " PushEvent ", "PushEvent" ]).event_types).to eq([ "PushEvent" ])
    end
  end

  describe "#initialize" do
    it "refuses an object that does not satisfy the processor contract" do
      expect { described_class.new(processors: [ Object.new ]) }
        .to raise_error(ArgumentError, /must declare .event_type and respond to #call/)
    end
  end

  # The type-agnostic half of §7's taxonomy.
  describe "#process" do
    it "delegates a PushEvent to its processor" do
      outcome = registry.process(well_formed_envelope)

      expect(outcome).to be_push_event
      expect(outcome.event_type).to eq("PushEvent")
    end

    # §7 row 1: "Valid non-PushEvent — Ignored and counted, not quarantined."
    it "ignores an event of a type it does not implement" do
      outcome = registry.process(well_formed_envelope("type" => "WatchEvent",
                                                     "payload" => { "action" => "started" }))

      expect(outcome).to be_ignored
      expect(outcome.event_type).to eq("WatchEvent")
      expect(outcome.github_event_id).to eq("58000000001")
      expect(outcome.error_code).to be_nil
    end

    # This application has no WatchEvent processor and therefore no definition of a valid
    # WatchEvent. Validating fields it never persists would invent a schema for twenty-odd
    # unverified types and fill quarantine with rows nobody can act on.
    it "still ignores an unimplemented type whose other fields are missing" do
      outcome = registry.process("type" => "WatchEvent")

      expect(outcome).to be_ignored
    end

    it "does not count an ignored event as a push event seen" do
      expect(registry.process("type" => "WatchEvent")).not_to be_push_type
    end

    # §7 row 3, structural half. EventSources::Base#events returns elements untouched,
    # "including nulls, which a valid JSON array can legitimately contain".
    it "quarantines a null element" do
      outcome = registry.process(nil)

      expect(outcome).to be_quarantined
      expect(outcome.error_code).to eq("invalid_envelope")
      expect(outcome.event_type).to be_nil
      expect(outcome.github_event_id).to be_nil
      expect(outcome.payload_fingerprint).to eq(Github::Events::PayloadFingerprint.fingerprint(nil))
    end

    it "quarantines an element that is an array, a string, or a number" do
      [ [], "PushEvent", 42, true ].each do |element|
        outcome = registry.process(element)

        expect(outcome).to be_quarantined, "expected #{element.inspect} to quarantine"
        expect(outcome.error_code).to eq("invalid_envelope")
      end
    end

    it "quarantines an envelope with no type, keeping the event id for traceability" do
      envelope = well_formed_envelope.except("type")

      outcome = registry.process(envelope)

      expect(outcome.error_code).to eq("missing_event_type")
      expect(outcome.github_event_id).to eq("58000000001")
      expect(outcome.event_type).to be_nil
    end

    # event_type is a text column; a coerced Integer written into it would make the
    # quarantine table lie about what arrived.
    it "quarantines an envelope whose type is not a string" do
      outcome = registry.process(well_formed_envelope("type" => 123))

      expect(outcome.error_code).to eq("missing_event_type")
      expect(outcome.event_type).to be_nil
      expect(outcome.error_message).to include("Integer")
    end

    it "quarantines an envelope whose type is blank" do
      expect(registry.process(well_formed_envelope("type" => "")).error_code).to eq("missing_event_type")
    end

    # §7: "the same github_event_id arriving with a different malformed payload is a
    # different quarantine row" — which only holds if the fingerprint covers the whole
    # envelope rather than just its payload.
    it "gives two typeless envelopes that differ only in actor distinct identities" do
      one = registry.process(well_formed_envelope("actor" => { "id" => 1 }).except("type"))
      other = registry.process(well_formed_envelope("actor" => { "id" => 2 }).except("type"))

      expect(one.github_event_id).to eq(other.github_event_id)
      expect(one.payload_fingerprint).not_to eq(other.payload_fingerprint)
    end
  end
end
