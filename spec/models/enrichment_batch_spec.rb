require "rails_helper"

RSpec.describe EnrichmentBatch do
  # One row per REQUEST attempt (Appendix F): the durable envelope a search or detail
  # fetch is audited against. correlation_id is passed explicitly because the model
  # validates presence before the database default could fill it in.
  def create_batch(**overrides)
    described_class.create!({
      request_kind: "search", entity_kind: "actor", started_at: frozen_time,
      correlation_id: SecureRandom.uuid
    }.merge(overrides))
  end

  def observation_for(batch)
    EnrichmentObservation.create!(
      enrichment_batch: batch, entity_kind: "actor", source: "search",
      observed_at: frozen_time, raw_payload: { "id" => 583_231, "login" => "octocat" },
      payload_fingerprint: "0" * 64, validation_outcome: "valid"
    )
  end

  describe "validations" do
    it "accepts both documented request kinds and nothing else" do
      described_class::REQUEST_KINDS.each do |kind|
        expect(create_batch(request_kind: kind)).to be_persisted
      end
      expect { create_batch(request_kind: "bulk") }
        .to raise_error(ActiveRecord::RecordInvalid, /Request kind/)
    end

    it "accepts both entity kinds and nothing else" do
      expect { create_batch(entity_kind: "organization") }
        .to raise_error(ActiveRecord::RecordInvalid, /Entity kind/)
    end

    it "accepts every documented status and rejects an invented one" do
      batch = create_batch

      described_class::STATUSES.each do |status|
        expect { batch.update!(status: status) }.not_to raise_error
      end
      expect { batch.update!(status: "abandoned") }
        .to raise_error(ActiveRecord::RecordInvalid, /Status/)
    end

    it "opens in flight, because the row is written before the request is issued" do
      expect(create_batch.status).to eq("in_flight")
    end

    it "requires the instant the attempt started" do
      expect { create_batch(started_at: nil) }
        .to raise_error(ActiveRecord::RecordInvalid, /Started at/)
    end

    it "rejects a negative counter" do
      %i[ requested_count returned_count valid_count missing_count invalid_count ].each do |counter|
        expect { create_batch(counter => -1) }
          .to raise_error(ActiveRecord::RecordInvalid)
      end
    end
  end

  describe "the correlation id" do
    # The column default is the server-side gen_random_uuid(), which Active Record
    # cannot evaluate before validation — so the model assigns one rather than letting
    # a caller that omitted it fail the presence rule below. Every claim site relies on
    # this: the observations written beside a batch carry its correlation id.
    it "is assigned when the caller supplies none" do
      batch = create_batch(correlation_id: nil)

      expect(batch.correlation_id).to be_present
    end

    # The uuid column casts a blank string to nil before validation, so the assignment
    # above catches that case too. The presence validation stays as the backstop that
    # would fail loudly if the assignment were ever removed.
    it "assigns one over a blank value rather than storing it" do
      batch = create_batch(correlation_id: "")

      expect(batch.correlation_id).to match(/\A[0-9a-f-]{36}\z/)
    end

    it "refuses a duplicate through the validation" do
      existing = create_batch

      expect { create_batch(correlation_id: existing.correlation_id) }
        .to raise_error(ActiveRecord::RecordInvalid, /Correlation/)
    end

    # The unique index is the arbiter under concurrency, where two validations can
    # both pass before either insert lands.
    it "refuses a duplicate at the database level even past the validation" do
      existing = create_batch
      rival = described_class.new(request_kind: "search", entity_kind: "actor",
                                  started_at: frozen_time,
                                  correlation_id: existing.correlation_id)

      expect_violation(ActiveRecord::RecordNotUnique) { rival.save!(validate: false) }
    end
  end

  # Audit evidence outlives its envelope's usefulness, never the other way around:
  # a batch with observations recorded against it cannot be deleted out from under
  # them.
  describe "deleting a batch that has observations" do
    it "is refused with an error rather than cascading or orphaning" do
      batch = create_batch
      observation_for(batch)

      expect(batch.destroy).to be(false)
      expect(batch.errors[:base]).to be_present
      expect(described_class.exists?(batch.id)).to be(true)
      expect(EnrichmentObservation.count).to eq(1)
    end

    it "permits deleting a batch nothing observed against" do
      batch = create_batch

      expect { batch.destroy! }.to change(described_class, :count).from(1).to(0)
    end
  end

  describe ".during" do
    it "selects by the instant the attempt started" do
      inside = create_batch(started_at: frozen_time)
      create_batch(started_at: frozen_time - 7200)

      expect(described_class.during((frozen_time - 3600)..frozen_time)).to eq([ inside ])
    end
  end
end
