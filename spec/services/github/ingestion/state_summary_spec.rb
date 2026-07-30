require "rails_helper"

RSpec.describe Github::Ingestion::StateSummary do
  def snapshot(**overrides)
    described_class.new(
      **{ latest_run_at: nil, latest_run_id: nil, push_event_count: 0,
          pending_actor_count: 0, pending_repository_count: 0,
          budget_resource: "core", budget_remaining: nil, budget_reset_at: nil,
          window_status: nil, source_present: true, next_poll_at: nil,
          global_blocked_until: nil }.merge(overrides)
    )
  end

  def rendered(**overrides)
    snapshot(**overrides).to_s.lines.map(&:chomp)
  end

  # The budget line is no longer the last one, and naming it beats counting to it.
  def budget_line(**overrides)
    rendered(**overrides).find { |line| line.start_with?("Budget remaining") }
  end

  describe ".capture" do
    it "reads a database with nothing in it without inventing anything" do
      expect(described_class.capture).to have_attributes(
        latest_run_at: nil, latest_run_id: nil, push_event_count: 0,
        pending_actor_count: 0, pending_repository_count: 0, window_status: nil
      )
    end

    it "reports persisted counts and the latest successful run" do
      source = create_event_source
      actor = create_actor(github_id: 1)
      repository = create_repository(github_id: 2)
      PushEvent.create!(push_event_attributes(actor: actor, repository: repository))
      IngestionRun.create!(event_source: source, started_at: frozen_time,
                           completed_at: frozen_time + 12, status: "completed")
      active_budget_window(now: frozen_time)

      summary = described_class.capture

      expect(summary).to have_attributes(
        push_event_count: 1, pending_actor_count: 1, pending_repository_count: 1,
        latest_run_at: frozen_time + 12, budget_remaining: 55, budget_resource: "core",
        budget_reset_at: frozen_time + 3600, window_status: "active"
      )
      expect(summary.latest_run_id).to eq(IngestionRun.sole.run_id)
    end

    it "ignores a failed or unfinished run when reporting the latest successful one" do
      source = create_event_source
      IngestionRun.create!(event_source: source, started_at: frozen_time,
                           completed_at: frozen_time + 1, status: "failed")
      IngestionRun.create!(event_source: source, started_at: frozen_time, status: "running")

      expect(described_class.capture.latest_run_at).to be_nil
    end

    # §9's "Latest successful run" — a 304 counts, because the poll succeeded and GitHub
    # reported nothing new.
    it "counts a 304 as a successful run" do
      IngestionRun.create!(event_source: create_event_source, started_at: frozen_time,
                           completed_at: frozen_time + 5, status: "not_modified")

      expect(described_class.capture.latest_run_at).to eq(frozen_time + 5)
    end

    # The ledger row is created by the first reservation, never by a read.
    it "does not create the ledger row it reports on" do
      expect { described_class.capture }.not_to change(GithubApiBudget, :count).from(0)
    end

    # §11 places the same guarantee on /status: reports persisted state only, never
    # initiates a GitHub request. Structural — this class holds no transport — and asserted
    # against a transport that records everything it is asked for.
    it "initiates no GitHub request" do
      transport = fixture_transport

      allow(Github).to receive(:transport).and_return(transport)
      expect(Github).not_to receive(:executor)

      described_class.capture

      expect(transport.requests).to be_empty
    end
  end

  describe "#to_s" do
    # Derived from §9's four sample lines, which all put their value at the same column.
    it "aligns every value on the shared report column" do
      column = Github::Ingestion::Report::LABEL_WIDTH

      rendered(push_event_count: 1_284).each do |line|
        expect(line[column - 1]).to eq(" "), "expected padding before the value in #{line.inspect}"
        expect(line[column]).not_to eq(" "), "expected the value to start at column #{column}"
      end
    end

    it "prints §9's lines" do
      lines = rendered(latest_run_at: Time.utc(2026, 7, 29, 14, 0, 12),
                       latest_run_id: "2f5b9c3e", push_event_count: 1_284,
                       pending_actor_count: 312, pending_repository_count: 407,
                       budget_remaining: 31, budget_reset_at: Time.utc(2026, 7, 29, 14, 32, 0),
                       window_status: "active", next_poll_at: Time.utc(2026, 7, 29, 14, 5, 0))

      expect(lines).to eq([
        "Latest successful run:            2026-07-29T14:00:12Z (run_id 2f5b9c3e)",
        "Persisted push events:            1,284",
        "Pending actor enrichments:        312",
        "Pending repository enrichments:   407",
        "Next poll due:                    2026-07-29T14:05:00Z",
        "Budget remaining (core):          31 (window resets 2026-07-29T14:32:00Z)",
        "Global block:                     none"
      ])
    end

    it "says so plainly when no run has ever succeeded" do
      expect(rendered.first).to include("none yet")
    end

    # §16 forbids a misleading guarantee, and printing 0 remaining on a fresh install would
    # be one — it would read as an exhausted budget.
    it "distinguishes an absent ledger row from an exhausted budget" do
      expect(budget_line).to include("not yet initialized")
      expect(budget_line(window_status: "uninitialized")).to include("unknown (window uninitialized)")
      expect(budget_line(window_status: "active", budget_remaining: 0)).to end_with("0")
    end

    it "omits the reset window when there is none to report" do
      expect(budget_line(window_status: "active", budget_remaining: 12))
        .to eq("Budget remaining (core):          12")
    end

    # Read from the row rather than hardcoded, so a future authenticated configuration is a
    # data change.
    it "names the rate-limit resource the ledger is tracking" do
      expect(budget_line(budget_resource: "search")).to start_with("Budget remaining (search):")
    end

    # The two scheduling lines exist for the busy path: on Errors::SourceBusy no run
    # happened, so there is no deferral line at all, and this block is the only place a
    # reviewer can learn when the next poll is or why nothing is moving.
    describe "the scheduling lines" do
      it "names the instant the next poll becomes due" do
        expect(rendered(next_poll_at: Time.utc(2026, 7, 30, 15, 5, 0))[4])
          .to eq("Next poll due:                    2026-07-30T15:05:00Z")
      end

      # nil means "no constraint applies", the same as it does in PollSchedule — spelled
      # out rather than left as a blank a reader would have to interpret.
      it "says a source with nothing holding it back is due now" do
        expect(rendered[4]).to end_with("due now")
      end

      it "distinguishes a source that does not exist yet from one that is due" do
        expect(rendered(source_present: false)[4]).to end_with("not yet provisioned")
      end

      # Not derivable from window_status: blocking is derived from this timestamp alone, so
      # a block can outlive the window that produced it and a stale label can never strand
      # the row. Without this line a window_status of globally_blocked has no explanation.
      it "names a global block and the instant it lifts" do
        expect(rendered(global_blocked_until: Time.utc(2026, 7, 30, 15, 0, 0)).last)
          .to eq("Global block:                     until 2026-07-30T15:00:00Z")
      end
    end
  end

  describe "#to_log" do
    it "renders timestamps the same way the printed block does" do
      log = snapshot(latest_run_at: Time.utc(2026, 7, 29, 14, 0, 12), window_status: "active",
                     budget_reset_at: Time.utc(2026, 7, 29, 14, 32, 0)).to_log

      expect(log).to include(latest_run_at: "2026-07-29T14:00:12Z",
                             budget_reset_at: "2026-07-29T14:32:00Z")
    end
  end
end
