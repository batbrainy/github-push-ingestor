require "rails_helper"

RSpec.describe Github::Enrichment::Summary do
  let(:now) { frozen_time }

  def capture(**overrides)
    described_class.capture(now: now, **overrides)
  end

  describe ".capture" do
    it "carries each class's backlog entry from the shared aggregate" do
      create_actor(github_id: 1, created_at: now - 600)
      create_repository(github_id: 2, created_at: now - 300)

      summary = capture

      expect(summary.actor).to have_attributes(
        status_counts: { "pending" => 1 }, contract_backlog_count: 1,
        oldest_pending_at: now - 600, oldest_pending_age_seconds: 600
      )
      expect(summary.repository).to have_attributes(
        contract_backlog_count: 1, oldest_pending_at: now - 300
      )
    end

    it "reports the detail-fallback budget against the guarantees the ledger enforces" do
      active_budget_window(now: now, enrichment_used: 4,
                           actor_share_used: 3, repository_share_used: 1)

      expect(capture).to have_attributes(
        detail_used: 4, detail_allowance: 4,
        actor_share_used: 3, repository_share_used: 1,
        actor_guarantee: 2, repository_guarantee: 2,
        window_status: "active", window_ready: true
      )
    end

    it "projects the search ledger's spend against its spendable ceiling" do
      active_search_window(now: now, used: 3)

      expect(capture).to have_attributes(
        search_present: true, search_used: 3, search_spendable: 8,
        search_remaining: 9, search_blocked_until: nil, next_search_at: nil
      )
    end

    # Nothing seeds either ledger row — only a reservation creates one — so a clean
    # checkout is the ordinary state rather than an error.
    it "reports no ledger rather than a fabricated zero on a clean checkout" do
      summary = capture

      expect(summary).to have_attributes(detail_used: nil, detail_allowance: nil,
                                         search_present: false, search_used: nil)
      expect(summary.to_s).to include(described_class::NO_LEDGER)
    end

    # The same structural guarantee Github::Ingestion::StateSummary carries, and §11
    # places on /status: no executor, no transport, no ledger writer.
    it "never initiates a GitHub request" do
      transport = fixture_transport
      allow(Github).to receive(:transport).and_return(transport)

      capture

      expect(transport.requests).to be_empty
    end

    it "does not create the ledger rows it reads, which only a reservation may" do
      expect { capture }.not_to change(GithubApiBudget, :count).from(0)
      expect { capture }.not_to change(GithubSearchBudget, :count).from(0)
    end

    # /status reads each singleton once and passes both down, so its blocks cannot
    # straddle a committing reservation and disagree about one instant.
    it "projects the rows it was handed rather than reading its own" do
      active_budget_window(now: now, enrichment_used: 3)
      active_search_window(now: now, used: 5)
      budget = current_budget
      search_budget = current_search_budget
      allow(GithubApiBudget).to receive(:find_by)
      allow(GithubSearchBudget).to receive(:find_by)

      summary = capture(budget: budget, search_budget: search_budget)

      expect(summary).to have_attributes(detail_used: 3, search_used: 5)
    end
  end

  describe "#claimable_now" do
    # The batch lane needs no core window: the Search ledger self-bootstraps from
    # configuration, so a missing row is a grant and never-enriched work is claimable
    # on a fresh checkout.
    it "is true when search is admissible and batch backlog exists" do
      create_actor(github_id: 1)

      expect(capture).to have_attributes(claimable_now: true, next_enrichment_at: nil)
      expect(capture.to_s).to include(described_class::DUE_NOW)
    end

    # Pacing is a wait, not a refusal — a cycle sleeps through it, so paced work is
    # still "due now" rather than deferred to an instant.
    it "is true while search pacing holds, because a cycle waits pacing out" do
      active_search_window(now: now, last_request_at: now - 2)
      create_actor(github_id: 1)

      expect(capture).to have_attributes(claimable_now: true, next_enrichment_at: nil)
    end

    it "is true via the detail lane when the core window grants and fallback work waits" do
      active_budget_window(now: now)
      create_actor(github_id: 1, enrichment_stage: "detail_pending",
                   detail_pending_at: now - 60)

      expect(capture).to have_attributes(claimable_now: true, next_enrichment_at: nil)
    end

    it "is false under a search block, however much batch work is waiting" do
      active_search_window(now: now, blocked_until: now + 30)
      create_actor(github_id: 1)

      expect(capture).to have_attributes(claimable_now: false,
                                         next_enrichment_at: now + 30)
    end

    it "is false when pacing holds but there is no work at all" do
      active_search_window(now: now, last_request_at: now - 2)

      summary = capture

      expect(summary).to have_attributes(work_waiting: false, claimable_now: false,
                                         next_enrichment_at: nil)
      expect(summary.to_s).to include(described_class::NOTHING_WAITING)
    end

    # Detail work cannot ride the search grant: the fallback lane spends the core
    # ledger, and the core ledger's bootstrap discipline is no window, no enrichment.
    it "is false when only detail work waits and no poll has initialized the core window" do
      create_actor(github_id: 1, enrichment_stage: "detail_pending",
                   detail_pending_at: now - 60)

      summary = capture

      expect(summary).to have_attributes(claimable_now: false, window_ready: false,
                                         next_enrichment_at: nil)
      expect(summary.to_s).to include(described_class::WAITING_FOR_WINDOW)
    end

    it "is false when the detail-fallback allowance is spent, deferring to the reset" do
      active_budget_window(now: now, enrichment_used: 4)
      create_actor(github_id: 1, enrichment_stage: "detail_pending",
                   detail_pending_at: now - 60)

      expect(capture).to have_attributes(claimable_now: false,
                                         next_enrichment_at: now + 3600)
    end
  end

  describe "#next_enrichment_at" do
    it "names the pacing resume when paced search is not the lane the work needs" do
      active_search_window(now: now, last_request_at: now - 2)
      create_actor(github_id: 1, enrichment_stage: "detail_pending",
                   detail_pending_at: now - 60)

      expect(capture).to have_attributes(claimable_now: false,
                                         next_enrichment_at: now + 4)
    end

    it "names the backoff instant of a scheduled batch retry" do
      create_actor(github_id: 1, enrichment_status: "retryable_failure",
                   enrichment_stage: "retry_scheduled", next_retry_at: now + 120)

      expect(capture).to have_attributes(claimable_now: false,
                                         next_enrichment_at: now + 120)
    end

    it "names the expiry of a live lease, after which the rows are reclaimable" do
      create_actor(github_id: 1, enrichment_stage: "batch_in_flight",
                   lease_token: SecureRandom.uuid, leased_until: now + 300)

      expect(capture).to have_attributes(claimable_now: false,
                                         next_enrichment_at: now + 300)
    end

    it "names the instant the oldest fresh completed row crosses its refresh TTL" do
      create_actor(github_id: 1, enrichment_status: "complete",
                   enrichment_stage: "contract_complete",
                   fetched_at: now - 1000, last_seen_at: now)

      expect(capture.next_enrichment_at).to eq(now + 85_400)
    end

    it "is nil when a stale refresh is claimable right now" do
      create_actor(github_id: 1, enrichment_status: "complete",
                   enrichment_stage: "contract_complete",
                   fetched_at: now - 90_000, last_seen_at: now)

      expect(capture).to have_attributes(claimable_now: true, next_enrichment_at: nil)
    end

    it "takes the earliest instant across both classes and both mechanisms" do
      create_actor(github_id: 1, enrichment_status: "retryable_failure",
                   enrichment_stage: "retry_scheduled", next_retry_at: now + 120)
      create_repository(github_id: 2, enrichment_stage: "batch_in_flight",
                        lease_token: SecureRandom.uuid, leased_until: now + 90)

      expect(capture.next_enrichment_at).to eq(now + 90)
    end

    # A terminal row is finished: whatever timestamps it retains, it must never
    # schedule anything, and with nothing else in the table nothing is waiting.
    it "ignores a terminal row entirely" do
      create_actor(github_id: 1, enrichment_status: "permanent_failure",
                   enrichment_stage: "terminal", terminal_at: now - 60,
                   next_retry_at: now + 60)

      summary = capture

      expect(summary).to have_attributes(work_waiting: false, claimable_now: false,
                                         next_enrichment_at: nil)
      expect(summary.to_s).to include(described_class::NOTHING_WAITING)
    end
  end

  describe "#to_s" do
    # Every value lands in the same column as the block bin/ingest already prints, so a
    # reviewer reads the two as one report. A label that fills LABEL_WIDTH exactly gets
    # no padding, and its value runs straight into the colon — which is what this catches.
    it "column-aligns with the block bin/ingest already prints, so both read as one report" do
      active_budget_window(now: now)
      width = Github::Ingestion::Report::LABEL_WIDTH

      capture.to_s.lines.each do |line|
        expect(line[width - 1]).to eq(" "), "expected #{line.inspect} to pad its label to #{width}"
        expect(line[width]).not_to eq(" ")
      end
    end

    it "prints each class's contract backlog and oldest wait" do
      create_actor(github_id: 1, created_at: now - 300)
      create_actor(github_id: 2, enrichment_status: "complete",
                   enrichment_stage: "contract_complete", fetched_at: now)

      expect(capture.to_s).to include(
        "Actor contract backlog:", "1", "Oldest actor pending:", "300s old"
      )
    end

    # The search row is configuration-born rather than poll-born, so "not yet
    # initialized" simply means no search request has ever been attempted.
    it "says the search budget is not yet initialized before any search request" do
      expect(capture.to_s)
        .to include("Search budget:", described_class::NO_LEDGER)
    end

    it "prints search spend as used-of-spendable, appending the pacing resume" do
      active_search_window(now: now, used: 3, last_request_at: now - 2)

      expect(capture.to_s)
        .to include("3 of 8 spendable used", "next request #{(now + 4).utc.iso8601}")
    end

    # The reason claimable_now exists. A nil next_enrichment_at means "no deferral
    # applies", which is equally true of a claimable candidate and of an empty
    # backlog — and those are opposite reports to an operator.
    it "says nothing waiting rather than due now on an empty backlog" do
      expect(capture.to_s).to include(described_class::NOTHING_WAITING)
      expect(capture.to_s).not_to include(described_class::DUE_NOW)
    end
  end

  describe "#to_log" do
    it "publishes the staged-pipeline projection under stable keys" do
      active_budget_window(now: now, enrichment_used: 2, actor_share_used: 2)
      active_search_window(now: now, used: 3)
      create_actor(github_id: 1, created_at: now - 300)

      log = capture.to_log

      expect(log).to include(
        actor_counts: { "pending" => 1 },
        actor_contract_backlog_count: 1, repository_contract_backlog_count: 0,
        actor_oldest_pending_at: (now - 300).utc.iso8601,
        detail_used: 2, detail_allowance: 4, actor_share_used: 2,
        search_used: 3, search_spendable: 8, search_remaining: 9,
        window_status: "active", claimable_now: true
      )
      expect(log[:actor_stage_counts]).to include("batch_pending" => 1, "terminal" => 0)
    end

    # .compact keeps the log line honest on a clean checkout: an absent ledger produces
    # absent keys, never fabricated zeros.
    it "omits the budget keys no ledger row exists to answer" do
      log = capture.to_log

      expect(log).not_to include(:detail_used, :search_used, :next_enrichment_at)
      expect(log).to include(claimable_now: false)
    end
  end
end
