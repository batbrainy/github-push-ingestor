require "rails_helper"

RSpec.describe Github::Ingestion::RunRecorder do
  let(:event_source) { create_event_source }

  subject(:recorder) do
    described_class.new(event_source: event_source, run_id: run_id, clock: -> { frozen_time })
  end

  let(:run_id) { "2f5b9c3e-7a41-4d0c-9b62-1c8e5f0a4d33" }

  describe "#start!" do
    it "opens the run as running, with no completion time" do
      run = recorder.start!

      expect(run).to be_running
      expect(run.started_at).to eq(frozen_time)
      expect(run.completed_at).to be_nil
      expect(run.event_source).to eq(event_source)
    end

    # §11 requires run_id on the correlated log lines, and the first of those is emitted as
    # the run starts — so the value has to exist before the row does rather than being read
    # back from the column default.
    it "carries the correlation id the caller already holds, with no reload" do
      expect(recorder.start!.run_id).to eq(run_id)
      expect(recorder.run_id).to eq(run_id)
    end

    it "generates its own correlation id when the caller supplies none" do
      recorder = described_class.new(event_source: event_source)

      expect(recorder.run_id).to match(
        /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
      )
      expect(recorder.start!.run_id).to eq(recorder.run_id)
    end

    it "starts every counter at zero" do
      run = recorder.start!

      expect(IngestionRun::COUNTERS.map { |counter| run.public_send(counter) }).to all(eq(0))
    end
  end

  describe "#finish!" do
    let(:tally) do
      Github::Ingestion::Tally.empty
        .record_page(events_received: 8)
        .record(result: :created, push_type: true)
        .record(result: :quarantined, push_type: true)
        .record(result: :ignored, push_type: false)
    end

    it "writes the counters once, from the tally" do
      recorder.start!
      run = recorder.finish!(status: "completed", tally: tally)

      expect(run).to be_completed
      expect(run.completed_at).to eq(frozen_time)
      expect(run.pages_fetched).to eq(1)
      expect(run.events_received).to eq(8)
      expect(run.push_events_seen).to eq(2)
      expect(run.events_created).to eq(1)
      expect(run.events_quarantined).to eq(1)
    end

    it "leaves the counters at zero for a run that fetched nothing" do
      recorder.start!
      run = recorder.finish!(status: "deferred")

      expect(run).to be_deferred
      expect(IngestionRun::COUNTERS.map { |counter| run.public_send(counter) }).to all(eq(0))
    end

    it "records a failure reason" do
      recorder.start!
      run = recorder.finish!(status: "failed", last_error: "GitHub returned 500 (server_error)")

      expect(run).to be_failed
      expect(run.last_error).to eq("GitHub returned 500 (server_error)")
    end

    # The column is unbounded text, but a backtrace there is noise rather than context.
    it "truncates a very long failure reason" do
      recorder.start!
      run = recorder.finish!(status: "failed", last_error: "x" * 5_000)

      expect(run.last_error.length).to eq(described_class::MAX_ERROR_LENGTH)
    end

    it "refuses to finish a run that was never started" do
      expect { recorder.finish!(status: "completed") }
        .to raise_error(ArgumentError, /no run has been started/)
    end

    it "refuses a status outside the vocabulary" do
      recorder.start!

      expect { recorder.finish!(status: "finished") }
        .to raise_error(ActiveRecord::RecordInvalid, /Status is not included in the list/)
    end
  end

  describe "the status vocabulary" do
    it "is exactly §7's five states" do
      expect(IngestionRun::STATUSES).to eq(%w[running completed not_modified deferred failed])
    end

    # §9's "Latest successful run". A 304 counts: the poll succeeded and GitHub reported
    # nothing new.
    it "treats a completed run and a 304 as successful, and nothing else" do
      expect(IngestionRun::SUCCESSFUL_STATUSES).to eq(%w[completed not_modified])
    end

    it "orders the latest successful run first and excludes unfinished ones" do
      older = finished_run("completed", frozen_time)
      newer = finished_run("not_modified", frozen_time + 60)
      finished_run("failed", frozen_time + 120)
      IngestionRun.create!(event_source: event_source, started_at: frozen_time + 180, status: "running")

      expect(IngestionRun.latest_successful.pluck(:id)).to eq([ newer.id, older.id ])
    end
  end

  def finished_run(status, completed_at)
    IngestionRun.create!(event_source: event_source, started_at: frozen_time,
                         completed_at: completed_at, status: status)
  end
end
