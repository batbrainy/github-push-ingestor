require "rails_helper"

RSpec.describe Github::Enrichment::Summary do
  let(:now) { frozen_time }

  describe ".capture" do
    it "counts each class by status, which is what a sampling rate looks like" do
      create_actor(github_id: 1, enrichment_status: "complete", fetched_at: now)
      create_actor(github_id: 2, enrichment_status: "skipped_budget", skipped_at: now)
      create_repository(github_id: 3)

      summary = described_class.capture(now: now)

      expect(summary.actor_counts).to eq("complete" => 1, "skipped_budget" => 1)
      expect(summary.repository_counts).to eq("pending" => 1)
    end

    it "reports the per-class share usage against the guarantees the ledger enforces" do
      active_budget_window(now: now, actor_share_used: 6, repository_share_used: 5, enrichment_used: 11)

      expect(described_class.capture(now: now)).to have_attributes(
        actor_share_used: 6, repository_share_used: 5, enrichment_used: 11,
        actor_guarantee: 20, repository_guarantee: 20, enrichment_allowance: 40
      )
    end

    # Nothing seeds the ledger row — only a reservation creates it — so a clean checkout is
    # the ordinary state rather than an error.
    it "reports no ledger rather than a fabricated zero on a clean checkout" do
      expect(described_class.capture(now: now).actor_share_used).to be_nil
      expect(described_class.capture(now: now).to_s).to include(described_class::NO_LEDGER)
    end

    # The same structural guarantee Github::Ingestion::StateSummary carries, and §11 places
    # on /status: no executor, no transport, no ledger.
    it "never initiates a GitHub request" do
      transport = fixture_transport
      allow(Github).to receive(:transport).and_return(transport)

      described_class.capture(now: now)

      expect(transport.requests).to be_empty
    end

    it "does not create the ledger row it reads, which only a reservation may" do
      expect { described_class.capture(now: now) }.not_to change(GithubApiBudget, :count).from(0)
    end
  end

  describe "#next_enrichment_at" do
    it "is nil when something is claimable right now" do
      active_budget_window(now: now)
      create_actor(github_id: 1, last_seen_at: now - 60)

      expect(described_class.capture(now: now).next_enrichment_at).to be_nil
    end

    it "names the soonest instant at which a deferred candidate becomes claimable" do
      active_budget_window(now: now)
      create_actor(github_id: 1, last_seen_at: now - 60, next_retry_at: now + 120)

      expect(described_class.capture(now: now).next_enrichment_at).to eq(now + 120)
    end

    # §9's effective_enrichment_time, answered for the pool: a global block or an exhausted
    # class outranks any individual entity's retry.
    it "names the window reset when the class allowance is spent" do
      active_budget_window(now: now, enrichment_used: 40)
      create_actor(github_id: 1, last_seen_at: now - 60)

      expect(described_class.capture(now: now).next_enrichment_at).to eq(now + 3600)
    end

    it "names a global block when one outlasts everything else" do
      active_budget_window(now: now, global_blocked_until: now + 7200)

      expect(described_class.capture(now: now).next_enrichment_at).to eq(now + 7200)
    end
  end

  describe "#to_s" do
    # Every value lands in the same column as the block bin/ingest already prints, so a
    # reviewer reads the two as one report. A label that fills LABEL_WIDTH exactly gets no
    # padding, and its value runs straight into the colon — which is what this catches.
    it "column-aligns with the block bin/ingest already prints, so both read as one report" do
      active_budget_window(now: now)
      width = Github::Ingestion::Report::LABEL_WIDTH

      described_class.capture(now: now).to_s.lines.each do |line|
        expect(line[width - 1]).to eq(" "), "expected #{line.inspect} to pad its label to #{width}"
        expect(line[width]).not_to eq(" ")
      end
    end

    it "prints each class as pending, complete and skipped" do
      create_actor(github_id: 1)
      create_actor(github_id: 2, enrichment_status: "complete", fetched_at: now)
      active_budget_window(now: now)

      expect(described_class.capture(now: now).to_s).to include("Actors pending/complete/skipped:", "1 / 1 / 0")
    end

    it "says due now rather than printing an instant that has already passed" do
      active_budget_window(now: now)

      expect(described_class.capture(now: now).to_s).to include(described_class::DUE_NOW)
    end
  end
end
