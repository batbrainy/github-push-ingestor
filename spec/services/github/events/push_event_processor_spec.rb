require "rails_helper"

RSpec.describe Github::Events::PushEventProcessor do
  subject(:processor) { described_class.new }

  # The registry guarantees a Hash whose type is exactly "PushEvent" before this runs, so
  # every example here starts from a well-formed envelope and deviates in one field.
  def process(overrides = {})
    processor.call(well_formed_envelope(overrides))
  end

  describe "a well-formed envelope" do
    let(:outcome) { process }

    it "normalizes it into a push event" do
      expect(outcome).to be_push_event
      expect(outcome.github_event_id).to eq("58000000001")
      expect(outcome.event_type).to eq("PushEvent")
      expect(outcome.occurred_at).to eq(Time.utc(2026, 7, 29, 11, 58, 12))
    end

    it "extracts §7's five required fields into typed columns" do
      expect(outcome.push_event_attributes).to include(
        github_event_id: "58000000001",
        github_push_id: 27_500_000_001,
        github_repository_id: 1_296_269,
        github_actor_id: 583_231,
        ref: "refs/heads/main",
        head_sha: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0",
        before_sha: "0f9e8d7c6b5a4938271605f4e3d2c1b0a9988776",
        occurred_at: Time.utc(2026, 7, 29, 11, 58, 12)
      )
    end

    # §7's envelope-to-stub mapping, which the plan states field by field.
    it "maps the actor envelope onto identity fields only" do
      expect(outcome.actor_attributes).to eq(
        github_id: 583_231,
        login: "octocat",
        display_login: "octocat",
        api_url: "https://api.github.com/users/octocat",
        avatar_url: "https://avatars.githubusercontent.com/u/583231?"
      )
    end

    # §7: repo.name is the qualified owner/repository form and is "not silently equated
    # with the enriched name".
    it "maps repo.name onto full_name and derives name from its final segment" do
      expect(outcome.repository_attributes).to eq(
        github_id: 1_296_269,
        full_name: "octocat/Hello-World",
        name: "Hello-World",
        api_url: "https://api.github.com/repos/octocat/Hello-World"
      )
    end

    it "leaves name nil when full_name is not actually qualified" do
      outcome = process("repo" => { "name" => "unqualified" })

      expect(outcome.repository_attributes).to include(full_name: "unqualified", name: nil)
    end

    it "retains the whole envelope as raw_payload, not just the payload" do
      expect(outcome.raw_payload).to eq(well_formed_envelope)
      expect(outcome.push_event_attributes[:raw_payload]).to eq(well_formed_envelope)
    end
  end

  # §7: "The parser requires these fields but tolerates additional unknown fields —
  # GitHub can add response fields without a new API version."
  describe "tolerance" do
    it "ignores an unknown payload field and keeps it in raw_payload" do
      outcome = process("payload" => { "pusher_type" => "user" })

      expect(outcome).to be_push_event
      expect(outcome.raw_payload.dig("payload", "pusher_type")).to eq("user")
    end

    it "ignores an unknown envelope field" do
      expect(process("org" => { "id" => 1, "login" => "github" })).to be_push_event
    end

    # §7 and Appendix D item 6: 40 hex under SHA-1, 64 under SHA-256.
    it "accepts both a 40- and a 64-character object name" do
      outcome = process("payload" => { "head" => sha_64, "before" => sha_40 })

      expect(outcome).to be_push_event
      expect(outcome.push_event_attributes).to include(head_sha: sha_64, before_sha: sha_40)
    end

    it "accepts an uppercase object name" do
      expect(process("payload" => { "head" => sha_40.upcase })).to be_push_event
    end

    it "normalizes an Integer event id to the same text as the String form" do
      outcome = process("id" => 58_000_000_001)

      expect(outcome.github_event_id).to eq("58000000001")
    end

    it "treats an optional identity field of the wrong shape as absent" do
      outcome = process("actor" => { "display_login" => { "unexpected" => true } })

      expect(outcome).to be_push_event
      expect(outcome.actor_attributes[:display_login]).to be_nil
    end
  end

  describe "the quarantine taxonomy" do
    # Each row states the one deviation and the code it must produce. Written as a table
    # because the codes are permanent — QuarantinedEvent never refreshes error_code — so
    # what matters is that one specific input yields one specific code.
    {
      "an absent event id" => [ { "id" => nil }, "missing_event_id" ],
      "a blank event id" => [ { "id" => "" }, "missing_event_id" ],
      "an event id of the wrong type" => [ { "id" => 1.5 }, "missing_event_id" ],
      "an absent actor" => [ { "actor" => nil }, "invalid_actor_reference" ],
      "an actor that is not an object" => [ { "actor" => [] }, "invalid_actor_reference" ],
      "an absent actor id" => [ { "actor" => { "id" => nil } }, "invalid_actor_reference" ],
      "a non-integer actor id" => [ { "actor" => { "id" => "583231" } }, "invalid_actor_reference" ],
      "a blank actor login" => [ { "actor" => { "login" => "" } }, "invalid_actor_reference" ],
      "an absent actor login" => [ { "actor" => { "login" => nil } }, "invalid_actor_reference" ],
      "an absent repo" => [ { "repo" => nil }, "invalid_repository_reference" ],
      "an absent repo id" => [ { "repo" => { "id" => nil } }, "invalid_repository_reference" ],
      "a blank repo name" => [ { "repo" => { "name" => "" } }, "invalid_repository_reference" ],
      "an absent created_at" => [ { "created_at" => nil }, "invalid_occurred_at" ],
      "an unparseable created_at" => [ { "created_at" => "yesterday" }, "invalid_occurred_at" ],
      "a created_at of the wrong type" => [ { "created_at" => 1_753_790_292 }, "invalid_occurred_at" ],
      "a payload that is not an object" => [ { "payload" => [] }, "missing_required_field" ],
      "a null payload field" => [ { "payload" => { "push_id" => nil } }, "missing_required_field" ],
      "a blank ref" => [ { "payload" => { "ref" => "" } }, "invalid_field_format" ],
      "a ref of the wrong type" => [ { "payload" => { "ref" => 42 } }, "invalid_field_format" ],
      "an object name that is not hexadecimal" => [
        { "payload" => { "head" => "not-a-valid-object-name" } }, "invalid_field_format"
      ],
      "an object name of the wrong length" => [ { "payload" => { "before" => "abc123" } }, "invalid_field_format" ],
      "a non-integer push id" => [ { "payload" => { "push_id" => "27500000001" } }, "invalid_field_format" ]
    }.each do |description, (overrides, expected_code)|
      it "quarantines #{description} as #{expected_code}" do
        outcome = process(overrides)

        expect(outcome).to be_quarantined
        expect(outcome.error_code).to eq(expected_code)
      end
    end

    # §7's integrity row: "payload.repository_id != repo.id — Quarantined as an integrity
    # failure". Neither identifier can be trusted as the foreign key once they disagree.
    it "quarantines a repository identifier that the envelope and the payload disagree on" do
      outcome = process("payload" => { "repository_id" => 999_999 })

      expect(outcome.error_code).to eq("repository_id_mismatch")
      expect(outcome.error_message).to include("999999", "1296269")
    end

    it "quarantines an identifier too large for a bigint column" do
      outcome = process("payload" => { "push_id" => 2**63 })

      expect(outcome.error_code).to eq("identifier_out_of_range")
    end

    it "records the event type and id on the quarantine outcome so the row is traceable" do
      outcome = process("payload" => { "head" => nil })

      expect(outcome.event_type).to eq("PushEvent")
      expect(outcome.github_event_id).to eq("58000000001")
      expect(outcome.payload_fingerprint).to match(/\A[0-9a-f]{64}\z/)
    end

    it "emits only codes that are members of the taxonomy" do
      outcome = process("payload" => nil)

      expect(Github::Events::QuarantineReasons::CODES).to include(outcome.error_code)
    end
  end

  describe "precedence when an envelope is broken several ways" do
    # Shape before integrity. A String "1296269" is != the Integer 1296269, so
    # integrity-first would report a mismatch that does not exist and hide the real defect.
    it "reports the unusable shape rather than a mismatch it would fabricate" do
      outcome = process("payload" => { "repository_id" => "1296269" })

      expect(outcome.error_code).to eq("invalid_field_format")
      expect(outcome.error_message).not_to include("does not match")
    end

    it "reports envelope identity before payload contents" do
      outcome = process("id" => nil, "payload" => { "head" => nil })

      expect(outcome.error_code).to eq("missing_event_id")
      expect(outcome.error_message).to include("payload is missing head")
    end

    it "reports absence before unusable shape" do
      outcome = process("payload" => { "head" => nil, "before" => "abc123" })

      expect(outcome.error_code).to eq("missing_required_field")
    end

    # Mirroring Errors::UrlPolicyViolation, which carries every reason "so a log line
    # names the whole problem".
    it "names every violation in the message even though one code wins" do
      outcome = process("id" => nil, "actor" => nil, "payload" => { "head" => "nope" })

      expect(outcome.error_message).to include("id is absent")
      expect(outcome.error_message).to include("actor is absent")
      expect(outcome.error_message).to include("payload.head")
    end
  end

  # The write path is guarded by validate! inside insert_if_new and upsert_stub!, and
  # PushEvent's own comment says reaching that raise "means the parser let something
  # through". These examples prove it cannot: for every taxonomy input, the outcome is a
  # quarantine, and for every accepted outcome the models validate.
  describe "the union of what the models require" do
    it "accepts every attribute set the three models validate" do
      outcome = process

      expect { PushEvent.new(outcome.push_event_attributes).validate! }.not_to raise_error
      expect { GithubActor.new(**outcome.actor_attributes).validate! }.not_to raise_error
      expect { GithubRepository.new(**outcome.repository_attributes).validate! }.not_to raise_error
    end

    it "quarantines rather than producing an attribute set a model would reject" do
      broken = [
        { "actor" => { "login" => nil } },
        { "repo" => { "name" => nil } },
        { "payload" => { "head" => "zz" } },
        { "created_at" => "" }
      ]

      broken.each do |overrides|
        expect(process(overrides)).to be_quarantined, "expected #{overrides.inspect} to quarantine"
      end
    end
  end

  # A non-finite Float — JSON.parse("1e400") yields Float::INFINITY — can be neither
  # fingerprinted nor stored in jsonb, so it has no quarantine row available to it. Both
  # halves of that boundary are pinned here, because where the failure surfaces decides
  # which counter it lands in.
  describe "a payload that cannot be represented in JSON" do
    let(:unstorable) { JSON.parse("[1e400]").first }

    it "raises when it would have to fingerprint one, rather than inventing an identity" do
      envelope = well_formed_envelope("payload" => { "head" => nil })
      envelope["payload"]["weight"] = unstorable

      expect { processor.call(envelope) }.to raise_error(ArgumentError, /not representable in JSON/)
    end

    it "does not fingerprint a healthy envelope, so the value surfaces at the write instead" do
      envelope = well_formed_envelope
      envelope["payload"]["weight"] = unstorable

      expect(processor.call(envelope)).to be_push_event
    end
  end
end
