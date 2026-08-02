require "rails_helper"

RSpec.describe Github::Enrichment::Summary do
  let(:now) { frozen_time }

  describe ".capture" do
    it "reports raw statuses and the durable backlog separately" do
      create_actor(github_id: 1, enrichment_status: "complete", fetched_at: now)
      create_actor(github_id: 2, enrichment_status: "retryable_failure",
                   next_retry_at: now + 3600, created_at: now - 600)
      create_repository(github_id: 3, created_at: now - 300)

      summary = described_class.capture(now: now)

      expect(summary.actor_counts).to eq("complete" => 1, "retryable_failure" => 1)
      expect(summary.repository_counts).to eq("pending" => 1)
      expect(summary).to have_attributes(
        actor_backlog_count: 1, repository_backlog_count: 1,
        actor_oldest_pending_at: now - 600,
        repository_oldest_pending_at: now - 300,
        actor_oldest_pending_age_seconds: 600,
        repository_oldest_pending_age_seconds: 300
      )
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

    it "does not claim enrichment can run before a poll initializes the window" do
      create_actor(github_id: 1)

      summary = described_class.capture(now: now)

      expect(summary).to have_attributes(claimable_now: false, next_enrichment_at: nil)
      expect(summary.to_s).to include(described_class::WAITING_FOR_WINDOW)
    end

    it "still says nothing is waiting on an empty clean checkout" do
      summary = described_class.capture(now: now)

      expect(summary).to have_attributes(work_waiting: false, claimable_now: false,
                                         next_enrichment_at: nil)
      expect(summary.to_s).to include(described_class::NOTHING_WAITING)
      expect(summary.to_s).not_to include(described_class::WAITING_FOR_WINDOW)
    end

    it "treats an existing uninitialized ledger the same way" do
      Github::BudgetLedger.new.bootstrap!(now: now)
      create_actor(github_id: 1)

      expect(described_class.capture(now: now))
        .to have_attributes(window_status: "uninitialized", claimable_now: false,
                            next_enrichment_at: nil)
    end

    [ 0, 40 ].each do |used|
      it "waits for a poll after an old window elapses with #{used} enrichment attempts used" do
        active_budget_window(now: now - 3600, reset_at: now - 1,
                             enrichment_used: used,
                             actor_share_used: used / 2,
                             repository_share_used: used / 2)
        create_actor(github_id: 1)

        summary = described_class.capture(now: now)

        expect(summary).to have_attributes(window_ready: false, work_waiting: true,
                                           claimable_now: false, next_enrichment_at: nil)
        expect(summary.to_s).to include(described_class::WAITING_FOR_WINDOW)
      end
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

    # The state the deterministic fixture run actually reaches, and the one that made this
    # line contradict the command it is printed beside: with every entity enriched and
    # inside its TTL, the next legal action is a refresh, not an enrichment now.
    it "names the refresh instant when the whole backlog is enriched and fresh" do
      active_budget_window(now: now)
      create_actor(github_id: 1, enrichment_status: "complete", fetched_at: now, last_seen_at: now - 60)

      expect(described_class.capture(now: now).next_enrichment_at).to eq(now + 86_400)
    end

    # A retryable failure on a refresh keeps the row complete, so it is invisible to the
    # pending pool while still being genuinely deferred.
    it "names the backoff of a refresh that failed, which the pending pool cannot see" do
      active_budget_window(now: now)
      create_actor(github_id: 1, enrichment_status: "complete", fetched_at: now - 90_000,
                   next_retry_at: now + 300, last_seen_at: now - 60)

      expect(described_class.capture(now: now).next_enrichment_at).to eq(now + 300)
    end

    # Deriving "claimable now" from "no deferred pending row" got this backwards: work was
    # available, and the report named an instant instead of saying so.
    it "is nil when one candidate is due even though another is deferred" do
      active_budget_window(now: now)
      create_actor(github_id: 1, last_seen_at: now - 60)
      create_actor(github_id: 2, last_seen_at: now - 60, next_retry_at: now + 300)

      expect(described_class.capture(now: now).next_enrichment_at).to be_nil
    end

    it "is nil when a stale refresh is the work that is waiting" do
      active_budget_window(now: now)
      create_actor(github_id: 1, enrichment_status: "complete", fetched_at: now - 90_000)

      expect(described_class.capture(now: now).next_enrichment_at).to be_nil
    end

    it "does not report a refresh due while first-time backlog is backed off" do
      active_budget_window(now: now)
      create_actor(github_id: 1, enrichment_status: "complete", fetched_at: now - 90_000)
      create_repository(github_id: 2, enrichment_status: "retryable_failure",
                        next_retry_at: now + 300)

      expect(described_class.capture(now: now))
        .to have_attributes(claimable_now: false, next_enrichment_at: now + 300)
    end

    it "takes the earliest across both classes" do
      active_budget_window(now: now)
      create_actor(github_id: 1, enrichment_status: "complete", fetched_at: now)
      create_repository(github_id: 2, last_seen_at: now - 60, next_retry_at: now + 90)

      expect(described_class.capture(now: now).next_enrichment_at).to eq(now + 90)
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

    it "prints each class's backlog and oldest wait" do
      create_actor(github_id: 1, created_at: now - 300)
      create_actor(github_id: 2, enrichment_status: "complete", fetched_at: now)
      active_budget_window(now: now)

      expect(described_class.capture(now: now).to_s).to include(
        "Actor backlog:", "1", "Oldest actor pending:", "300s old"
      )
    end

    it "says due now when a candidate is actually claimable" do
      create_actor(github_id: 1)
      active_budget_window(now: now)

      expect(described_class.capture(now: now).to_s).to include(described_class::DUE_NOW)
    end

    # The reason claimable_now exists. A nil next_enrichment_at means "no deferral
    # applies", which is equally true of a claimable candidate and of an empty backlog —
    # and this line used to say "due now" to a reviewer whose next line of output was
    # "nothing to enrich".
    it "says nothing waiting rather than due now on an empty backlog" do
      active_budget_window(now: now)

      expect(described_class.capture(now: now).to_s)
        .to include(described_class::NOTHING_WAITING)
    end
  end

  describe "#claimable_now" do
    it "is false when nothing is enrichable, so a nil instant is never ambiguous" do
      active_budget_window(now: now)

      expect(described_class.capture(now: now))
        .to have_attributes(claimable_now: false, next_enrichment_at: nil)
    end

    it "is true when a candidate could be claimed this second" do
      create_actor(github_id: 1)
      active_budget_window(now: now)

      expect(described_class.capture(now: now))
        .to have_attributes(claimable_now: true, next_enrichment_at: nil)
    end

    # A ledger block outranks every per-entity instant: the candidate is there, but no
    # request may be issued for it, so it is not claimable.
    it "is false under a global block, however many candidates are waiting" do
      create_actor(github_id: 1)
      active_budget_window(now: now, global_blocked_until: now + 300)

      expect(described_class.capture(now: now))
        .to have_attributes(claimable_now: false, next_enrichment_at: now + 300)
    end
  end

  describe "the ledger row it reports on" do
    # /status reads the singleton once and passes it down, so its poll block and its
    # ledger block cannot straddle a committing reservation and disagree.
    it "uses the row it was handed instead of reading its own" do
      active_budget_window(now: now, enrichment_used: 7)
      budget = current_budget
      allow(GithubApiBudget).to receive(:find_by)

      expect(described_class.capture(now: now, budget: budget).enrichment_used).to eq(7)
      expect(GithubApiBudget).not_to have_received(:find_by)
    end
  end
end
