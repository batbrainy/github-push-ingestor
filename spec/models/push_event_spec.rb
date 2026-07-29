require "rails_helper"

RSpec.describe PushEvent do
  let(:actor) { create_actor }
  let(:repository) { create_repository }
  let(:attributes) { push_event_attributes(actor: actor, repository: repository) }

  describe ".insert_if_new" do
    it "returns the new row id for a previously unseen event" do
      expect(described_class.insert_if_new(attributes)).to be_a(Integer)
      expect(described_class.count).to eq(1)
    end

    # The nil return is the durability gate: it is what tells the ingest transaction
    # this was a replay, so entity activity must not be updated (plan §7, §8).
    it "returns nil for a replayed event without inserting a second row" do
      described_class.insert_if_new(attributes)

      expect(described_class.insert_if_new(attributes)).to be_nil
      expect(described_class.count).to eq(1)
    end

    it "leaves an accepted event untouched when it is re-polled" do
      described_class.insert_if_new(attributes)
      original = described_class.sole

      described_class.insert_if_new(attributes.merge(ref: "refs/heads/rewritten"))

      expect(described_class.sole.ref).to eq(original.ref)
      expect(described_class.sole.updated_at).to eq(original.updated_at)
    end

    it "stores distinct events separately" do
      described_class.insert_if_new(attributes)
      described_class.insert_if_new(
        push_event_attributes(actor: actor, repository: repository,
                              github_event_id: "40000000002")
      )

      expect(described_class.count).to eq(2)
    end

    # insert bypasses Active Record validations, so insert_if_new validates
    # explicitly — without that, SHA_FORMAT would never run on the real write path.
    it "refuses a malformed SHA rather than persisting it" do
      expect { described_class.insert_if_new(attributes.merge(head_sha: "nope")) }
        .to raise_error(ActiveRecord::RecordInvalid)

      expect(described_class.count).to eq(0)
    end
  end

  describe "SHA format" do
    it "accepts a 40-character SHA-1 object name" do
      expect(described_class.new(attributes.merge(head_sha: sha_40))).to be_valid
    end

    it "accepts a 64-character SHA-256 object name" do
      expect(described_class.new(attributes.merge(head_sha: sha_64))).to be_valid
    end

    it "rejects lengths between and beyond the two valid widths" do
      [ sha_40.first(39), "#{sha_40}a", sha_64.first(63), "#{sha_64}a" ].each do |value|
        expect(described_class.new(attributes.merge(head_sha: value))).not_to be_valid
      end
    end

    it "rejects non-hexadecimal characters" do
      expect(described_class.new(attributes.merge(before_sha: "z" * 40))).not_to be_valid
    end
  end

  describe "raw payload retention" do
    # Retention is semantic, not byte-exact: jsonb discards whitespace and key order.
    # See docs/adr/0001-jsonb-semantic-retention.md.
    let(:source_json) do
      '{ "type" : "PushEvent",  "payload" : { "ref" : "refs/heads/main", "before" : null } }'
    end

    it "preserves the payload's content" do
      parsed = JSON.parse(source_json)
      described_class.insert_if_new(attributes.merge(raw_payload: parsed))

      expect(described_class.sole.raw_payload).to eq(parsed)
    end

    it "preserves nested structure, nulls, booleans, numbers, and Unicode" do
      payload = {
        "nested" => { "b" => 2, "a" => 1 },
        "array" => [ 3, 1, 2 ],
        "null" => nil,
        "bool" => true,
        "number" => 1234567890,
        "unicode" => "héllo ✨"
      }
      described_class.insert_if_new(attributes.merge(raw_payload: payload))

      expect(described_class.sole.raw_payload).to eq(payload)
      # Array order is meaningful and must survive; object key order is not.
      expect(described_class.sole.raw_payload["array"]).to eq([ 3, 1, 2 ])
    end

    it "does not retain the original bytes, which is the documented tradeoff" do
      described_class.insert_if_new(attributes.merge(raw_payload: JSON.parse(source_json)))

      stored = described_class.connection.select_value(
        "SELECT raw_payload::text FROM push_events LIMIT 1"
      )

      expect(stored).not_to eq(source_json)
      expect(JSON.parse(stored)).to eq(JSON.parse(source_json))
    end
  end

  describe "database constraints" do
    it "rejects a duplicate GitHub event id" do
      described_class.insert_if_new(attributes)

      # insert! rather than insert: insert_all hard-codes on_duplicate: :skip, which
      # would swallow the conflict and make this assertion vacuous.
      expect_violation(ActiveRecord::RecordNotUnique) { described_class.insert!(attributes) }
    end

    it "requires every structured field" do
      %i[github_event_id github_push_id github_repository_id github_actor_id
         ref head_sha before_sha occurred_at raw_payload].each do |column|
        expect_violation(ActiveRecord::NotNullViolation) do
          described_class.insert!(attributes.except(column))
        end
      end
    end

    it "rejects an event referencing an unknown actor" do
      expect_violation(ActiveRecord::InvalidForeignKey) do
        described_class.insert!(attributes.merge(github_actor_id: 999_999))
      end
    end

    it "rejects an event referencing an unknown repository" do
      expect_violation(ActiveRecord::InvalidForeignKey) do
        described_class.insert!(attributes.merge(github_repository_id: 999_999))
      end
    end
  end

  describe "associations" do
    it "reaches its actor and repository through their github_id" do
      described_class.insert_if_new(attributes)
      event = described_class.sole

      expect(event.github_actor).to eq(actor)
      expect(event.github_repository).to eq(repository)
    end
  end
end
