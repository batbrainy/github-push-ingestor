require "rails_helper"

RSpec.describe IngestionRun do
  let(:event_source) { create_event_source }

  def create_run(**overrides)
    described_class.create!(
      { event_source: event_source, started_at: frozen_time, status: "running" }
        .merge(overrides)
    )
  end

  describe "run correlation" do
    # run_id is the identifier shared by poller, worker, logs, and status output (§11),
    # so a row must never exist without one.
    it "is assigned by the database, not the caller" do
      expect(create_run.reload.run_id).to match(
        /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
      )
    end

    it "differs between runs" do
      expect(create_run.reload.run_id).not_to eq(create_run.reload.run_id)
    end

    it "is unique" do
      existing = create_run.reload

      # Braces are required: insert! takes the attribute hash positionally, and bare
      # key: value pairs would bind to its returning:/record_timestamps: keywords.
      expect_violation(ActiveRecord::RecordNotUnique) do
        described_class.insert!({
          event_source_id: event_source.id, started_at: frozen_time,
          status: "running", run_id: existing.run_id
        })
      end
    end
  end

  describe "counters" do
    it "start at zero" do
      run = create_run

      described_class::COUNTERS.each do |counter|
        expect(run.public_send(counter)).to eq(0), "expected #{counter} to default to 0"
      end
    end

    it "record the outcome of a cycle" do
      run = create_run(pages_fetched: 1, events_received: 100, push_events_seen: 92,
                       events_created: 90, duplicates_skipped: 1,
                       events_quarantined: 1, events_failed: 0,
                       completed_at: frozen_time + 12, status: "completed")

      expect(run.reload.events_created).to eq(90)
      expect(run.duplicates_skipped).to eq(1)
      expect(run.completed_at).to eq(frozen_time + 12)
    end

    it "rejects a negative counter at the database level" do
      run = create_run

      described_class::COUNTERS.each do |counter|
        expect_violation(ActiveRecord::CheckViolation) do
          described_class.where(id: run.id).update_all(counter => -1)
        end
      end
    end
  end

  describe "database constraints" do
    it "requires a source, a start time, and a status" do
      expect_violation(ActiveRecord::NotNullViolation) do
        described_class.insert!({ event_source_id: event_source.id, status: "running" })
      end

      expect_violation(ActiveRecord::NotNullViolation) do
        described_class.insert!({ event_source_id: event_source.id, started_at: frozen_time })
      end
    end

    it "rejects a run belonging to no source" do
      expect_violation(ActiveRecord::InvalidForeignKey) do
        described_class.insert!({ event_source_id: 999_999, started_at: frozen_time,
                                  status: "running" })
      end
    end
  end
end
