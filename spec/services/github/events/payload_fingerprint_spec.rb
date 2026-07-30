require "rails_helper"

RSpec.describe Github::Events::PayloadFingerprint do
  def canonical(document)
    described_class.canonical(document)
  end

  def fingerprint(document)
    described_class.fingerprint(document)
  end

  # Assertions are written against the canonical *string* rather than an opaque hex
  # constant, so each example documents the algorithm instead of memorising its output.
  # One golden digest at the end guards against a JSON or Digest library change.
  def digest_of(canonical_json)
    Digest::SHA256.hexdigest(canonical_json)
  end

  describe "the digest" do
    it "is 64 lowercase hexadecimal characters" do
      expect(fingerprint({ "id" => "58000000007" })).to match(/\A[0-9a-f]{64}\z/)
    end

    it "is SHA-256 of the canonical text" do
      document = { "b" => 1, "a" => 2 }

      expect(fingerprint(document)).to eq(digest_of('{"a":2,"b":1}'))
    end
  end

  # §7's required cases begin here: "nested key-order independence, array-order
  # preservation, nulls, booleans, Unicode strings, numerics, and payloads with and
  # without event IDs."
  describe "object keys" do
    it "sorts keys recursively, so nested key order cannot change the identity" do
      one = { "b" => 1, "a" => { "d" => 2, "c" => 3 } }
      other = { "a" => { "c" => 3, "d" => 2 }, "b" => 1 }

      expect(canonical(one)).to eq('{"a":{"c":3,"d":2},"b":1}')
      expect(fingerprint(one)).to eq(fingerprint(other))
    end

    it "sorts keys inside objects nested in arrays" do
      expect(canonical([ { "z" => 1, "a" => 2 } ])).to eq('[{"a":2,"z":1}]')
    end

    # Bytewise, therefore locale-independent: uppercase before lowercase, multi-byte
    # last. Pinned so a future sort_by or a locale-aware comparison is caught.
    it "sorts bytewise rather than by locale" do
      expect(canonical({ "é" => 1, "z" => 2, "a" => 3, "Z" => 4 })).to eq('{"Z":4,"a":3,"z":2,"é":1}')
    end

    it "refuses a non-String key, the one input that would make the order ambiguous" do
      expect { canonical({ a: 1 }) }.to raise_error(ArgumentError, /keys must be Strings/)
    end
  end

  describe "arrays" do
    it "preserves order, because array order is semantically meaningful" do
      expect(canonical([ 3, 1, 2 ])).to eq("[3,1,2]")
    end

    it "gives two differently ordered arrays different identities" do
      expect(fingerprint([ 3, 1, 2 ])).not_to eq(fingerprint([ 1, 2, 3 ]))
    end
  end

  describe "scalars" do
    it "canonicalizes nulls and booleans" do
      expect(canonical({ "t" => true, "f" => false, "n" => nil })).to eq('{"f":false,"n":null,"t":true}')
    end

    it "keeps a large integer exact rather than widening it to a float" do
      expect(canonical({ "push_id" => 27_500_000_001 })).to eq('{"push_id":27500000001}')
    end

    # Deliberate: the fingerprint normalizes key *order*, not numeric representation.
    # Merging 1 and 1.0 would fold two genuinely different payloads onto one row and
    # lose one of them permanently, because record! never refreshes raw_payload.
    # Over-splitting only ever costs one extra row.
    it "does not equate an integer with the same value as a float" do
      expect(canonical({ "n" => 1 })).to eq('{"n":1}')
      expect(canonical({ "n" => 1.0 })).to eq('{"n":1.0}')
      expect(fingerprint({ "n" => 1 })).not_to eq(fingerprint({ "n" => 1.0 }))
    end

    it "emits Unicode string values raw rather than escaped" do
      expect(canonical({ "k" => "héllo ✨" })).to eq('{"k":"héllo ✨"}')
    end

    it "produces UTF-8 text, so the digest is taken over the documented bytes" do
      expect(canonical({ "k" => "héllo ✨" }).encoding).to eq(Encoding::UTF_8)
    end
  end

  # Github::EventSources::Base#events returns array elements untouched, including
  # null, and §7 requires those to be quarantinable — so the function has to be total
  # over anything a JSON array element can be, not just over objects.
  describe "documents that are not objects" do
    it "canonicalizes a bare null" do
      expect(canonical(nil)).to eq("null")
      expect(fingerprint(nil)).to eq(digest_of("null"))
    end

    it "canonicalizes an empty array and an empty object, and tells them apart" do
      expect(canonical([])).to eq("[]")
      expect(canonical({})).to eq("{}")
      expect(fingerprint([])).not_to eq(fingerprint({}))
    end

    it "canonicalizes a bare string and a bare integer" do
      expect(canonical("x")).to eq('"x"')
      expect(canonical(5)).to eq("5")
    end
  end

  describe "payloads with and without an event ID" do
    let(:envelope) do
      {
        "id" => "58000000007",
        "type" => "PushEvent",
        "actor" => { "id" => 1_024_025, "login" => "monalisa" },
        "payload" => {}
      }
    end

    it "fingerprints both, and gives them different identities" do
      without_id = envelope.except("id")

      expect(fingerprint(envelope)).to match(/\A[0-9a-f]{64}\z/)
      expect(fingerprint(without_id)).to match(/\A[0-9a-f]{64}\z/)
      expect(fingerprint(envelope)).not_to eq(fingerprint(without_id))
    end

    # §7: "the same github_event_id arriving with a different malformed payload is a
    # different quarantine row". Two envelopes sharing an id must not collide.
    it "distinguishes two envelopes that share an event ID but differ elsewhere" do
      other = envelope.merge("actor" => { "id" => 583_231, "login" => "octocat" })

      expect(fingerprint(envelope)).not_to eq(fingerprint(other))
    end
  end

  describe "values outside the JSON data model" do
    it "refuses a Ruby object JSON.parse could never have produced" do
      expect { canonical({ "t" => Time.utc(2026, 1, 1) }) }
        .to raise_error(ArgumentError, /Time is outside the JSON data model/)
    end

    it "refuses a Symbol value" do
      expect { canonical({ "t" => :push }) }.to raise_error(ArgumentError, /Symbol/)
    end

    # JSON.parse("1e400") succeeds and yields Float::INFINITY. Naming it here means the
    # ERROR log says what happened instead of surfacing a JSON::GeneratorError from
    # three frames down — and such a payload cannot be stored in jsonb either, so its
    # only terminal outcome is events_failed.
    it "refuses a non-finite float, which JSON.parse can produce from an overflowing literal" do
      overflowed = JSON.parse("[1e400]")

      expect(overflowed.first).to be_infinite
      expect { canonical(overflowed) }.to raise_error(ArgumentError, /not representable in JSON/)
    end
  end

  # A library upgrade that changed compactness, escaping, or the digest itself would
  # silently re-key every row already in quarantined_events. This is the tripwire.
  describe "stability across library versions" do
    it "still produces the recorded digest for a fixed document" do
      document = { "b" => [ 1, { "d" => nil, "c" => true } ], "a" => "é" }

      expect(canonical(document)).to eq('{"a":"é","b":[1,{"c":true,"d":null}]}')
      expect(fingerprint(document))
        .to eq("419018b114d9c9219b9a1c2662a692fae509085787bd07f914579861ae91747f")
    end
  end
end
