require "rails_helper"

RSpec.describe EventSource do
  describe "scheduling components" do
    # Plan §9: the constraints are persisted separately, never collapsed into one
    # timestamp — otherwise --force could not tell which part it may bypass, and a
    # routine X-RateLimit-Reset would wrongly defer every poll to the top of the hour.
    it "holds each component independently" do
      source = create_event_source(
        cadence_due_at: frozen_time + 300,
        poll_floor_until: frozen_time + 60,
        retry_not_before_at: frozen_time + 900,
        next_poll_at: frozen_time + 900
      )

      source.reload
      expect(source.cadence_due_at).to eq(frozen_time + 300)
      expect(source.poll_floor_until).to eq(frozen_time + 60)
      expect(source.retry_not_before_at).to eq(frozen_time + 900)
      expect(source.next_poll_at).to eq(frozen_time + 900)
    end

    it "leaves every component unset on a new source" do
      source = create_event_source

      expect(source.cadence_due_at).to be_nil
      expect(source.poll_floor_until).to be_nil
      expect(source.retry_not_before_at).to be_nil
      expect(source.next_poll_at).to be_nil
    end

    it "can clear one component without disturbing the others" do
      source = create_event_source(cadence_due_at: frozen_time + 300,
                                   poll_floor_until: frozen_time + 60)

      source.update!(cadence_due_at: nil)

      expect(source.reload.poll_floor_until).to eq(frozen_time + 60)
    end
  end

  describe "rate-limit state" do
    # V1 stored rate-limit state per source; V2 moved it to the global ledger because
    # enrichment requests are not tied to a source row and the budget is per-IP (§7).
    it "keeps no per-source rate-limit columns" do
      expect(described_class.column_names.grep(/rate_limit|remaining|allowance/)).to be_empty
    end
  end

  describe "defaults" do
    it "is enabled with no failures and an empty configuration" do
      source = described_class.create!(source_type: "github_public_events", status: "idle")

      expect(source).to be_enabled
      expect(source.consecutive_failures).to eq(0)
      expect(source.configuration).to eq({})
    end
  end

  describe "the page-one ETag" do
    it "is stored per source and starts unset" do
      expect(create_event_source.etag).to be_nil
      expect(create_event_source(etag: 'W/"abc123"').etag).to eq('W/"abc123"')
    end
  end

  describe "database constraints" do
    it "requires a source type and a status" do
      %i[source_type status].each do |column|
        expect_violation(ActiveRecord::NotNullViolation) do
          described_class.insert!(event_source_attributes.except(column))
        end
      end
    end

    it "rejects a negative failure count" do
      source = create_event_source

      expect_violation(ActiveRecord::CheckViolation) do
        described_class.where(id: source.id).update_all(consecutive_failures: -1)
      end
    end

    # Several live sources may share a type — plan §6 anticipates per-repository event
    # sources — so the type is deliberately not unique.
    it "allows more than one source of the same type" do
      create_event_source
      expect { create_event_source }.to change(described_class, :count).by(1)
    end
  end

  describe "associations" do
    it "will not be destroyed while runs reference it" do
      source = create_event_source
      IngestionRun.create!(event_source: source, started_at: frozen_time, status: "running")

      expect(source.destroy).to be(false)
      expect(described_class.count).to eq(1)
    end
  end
end
