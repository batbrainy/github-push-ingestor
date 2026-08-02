require "rails_helper"

# The one rule both enqueue paths share (§8 steps 10 and 11): "is there staged enrichment
# work a cycle could do right now?", answered from the committed entity rows and the two
# ledgers, never from the queue.
RSpec.describe Github::Enrichment::Dispatch do
  subject(:dispatch) { described_class.new(clock: -> { frozen_time }) }

  def actor(**overrides)
    create_actor(github_id: 583_231, last_seen_at: frozen_time, **overrides)
  end

  def repository(**overrides)
    create_repository(github_id: 1_296_269, last_seen_at: frozen_time, **overrides)
  end

  def detail_pending!(model)
    model.update_all(enrichment_stage: "detail_pending", detail_pending_at: frozen_time)
  end

  before { active_budget_window(now: frozen_time) }

  describe "when there is claimable batch work" do
    # A missing search-ledger row is a grant: the search ledger self-bootstraps from
    # configuration, so a clean checkout's first committed entity is immediately claimable.
    it "enqueues exactly one cycle, whichever classes have work" do
      actor
      repository

      expect { dispatch.call(reason: "reconcile") }
        .to have_enqueued_job(EnrichmentCycleJob).exactly(:once)
      expect(ActiveJob::Base.queue_adapter.enqueued_jobs.map { _1[:job] }).to eq([ EnrichmentCycleJob ])
    end

    # However deep the backlog. EnrichmentCycleJob loops until a ledger denies, so queue
    # depth is set by the budgets, not by how many rows are waiting — 90 pending actors
    # would otherwise become 90 cycles the ledgers refuse most of.
    it "enqueues one cycle whether one entity is pending or fifty" do
      50.times { |index| create_actor(github_id: 1_000 + index, last_seen_at: frozen_time) }

      expect { dispatch.call(reason: "reconcile") }
        .to have_enqueued_job(EnrichmentCycleJob).exactly(:once)
    end

    # Pacing is a wait, not a refusal: the cycle sleeps it out on its own worker thread,
    # so a paced ledger is still admissible work.
    it "still enqueues while the search ledger is only pacing" do
      actor
      active_search_window(now: frozen_time, last_request_at: frozen_time - 2)

      expect { dispatch.call(reason: "reconcile") }
        .to have_enqueued_job(EnrichmentCycleJob).exactly(:once)
    end

    it "reports what it scheduled, and nothing that blocked" do
      actor

      expect(dispatch.call(reason: "ingestion")).to eq(cycle_enqueued: 1, reason: "ingestion")
    end

    # INFO only when it scheduled something. The rich per-stage summary lives on /status
    # and the one-shot now — this line carries the decision alone, so the exact-argument
    # match below is also the proof that no summary is merged onto it anymore.
    it "logs the bare decision at INFO, with no summary merged onto the line" do
      actor
      allow(Rails.logger).to receive(:info)

      dispatch.call(reason: "reconcile")

      expect(Rails.logger).to have_received(:info).with(
        event: "enrichment.dispatched", cycle_enqueued: 1, reason: "reconcile"
      )
    end
  end

  describe "when only detail-fallback work is claimable" do
    before do
      # Search denied outright (remaining at the reserve), so batch work alone could not
      # justify a cycle — the detail lane has to carry the decision.
      active_search_window(now: frozen_time, remaining: 2)
    end

    it "enqueues one cycle for a claimable detail row under a granted core window" do
      actor
      detail_pending!(GithubActor)

      expect { dispatch.call(reason: "reconcile") }
        .to have_enqueued_job(EnrichmentCycleJob).exactly(:once)
    end

    it "enqueues nothing when the core allowance is spent too" do
      actor
      detail_pending!(GithubActor)
      active_budget_window(now: frozen_time, enrichment_used: 4, reset_at: frozen_time + 600)

      expect { dispatch.call(reason: "reconcile") }.not_to have_enqueued_job
      expect(dispatch.call(reason: "reconcile"))
        .to include(blocked_by: [ :search_reserve_reached, :class_exhausted ])
    end
  end

  describe "when there is nothing claimable" do
    it "enqueues nothing when every entity is decided, and names both empty lanes" do
      actor(enrichment_status: "complete", enrichment_stage: "contract_complete",
            fetched_at: frozen_time)
      repository(enrichment_status: "permanent_failure", enrichment_stage: "terminal")

      expect { dispatch.call(reason: "reconcile") }.not_to have_enqueued_job
      expect(dispatch.call(reason: "reconcile"))
        .to include(blocked_by: [ :no_batch_work, :no_detail_work ])
    end

    # An entity another worker is mid-way through is not pending work: the live lease
    # excludes it from both claims until leased_until passes.
    it "enqueues nothing while the only candidate is leased by a live worker" do
      actor
      GithubActor.update_all(enrichment_stage: "batch_in_flight",
                             leased_until: frozen_time + 600)

      expect { dispatch.call(reason: "reconcile") }.not_to have_enqueued_job
    end

    # The steady state of an exhausted window, once a minute for the rest of the hour — the
    # volume argument Github::BudgetLedger#log_class_exhausted already makes.
    it "keeps the line at DEBUG so an idle tick is not INFO noise" do
      allow(Rails.logger).to receive(:info)
      allow(Rails.logger).to receive(:debug)

      dispatch.call(reason: "reconcile")

      expect(Rails.logger).to have_received(:debug).with(hash_including(event: "enrichment.dispatched"))
      expect(Rails.logger).not_to have_received(:info).with(hash_including(event: "enrichment.dispatched"))
    end
  end

  describe "when both ledgers deny" do
    # blocked_by is always the pair [search-side, detail-side], so an operator reads one
    # line and knows which lane to look at.
    it "enqueues nothing while the search ledger is blocked and no core window exists" do
      actor
      detail_pending!(GithubActor)
      active_search_window(now: frozen_time, blocked_until: frozen_time + 300)
      GithubApiBudget.delete_all

      expect { dispatch.call(reason: "reconcile") }.not_to have_enqueued_job
      expect(dispatch.call(reason: "reconcile"))
        .to include(blocked_by: [ :search_blocked, :window_uninitialized ])
    end

    it "enqueues nothing once the search ceiling and the detail allowance are both spent" do
      actor
      repository
      detail_pending!(GithubRepository)
      active_search_window(now: frozen_time, remaining: 5, used: 8)
      active_budget_window(now: frozen_time, enrichment_used: 4, reset_at: frozen_time + 600)

      expect { dispatch.call(reason: "reconcile") }.not_to have_enqueued_job
      expect(dispatch.call(reason: "reconcile"))
        .to include(blocked_by: [ :search_ceiling_exhausted, :class_exhausted ])
    end
  end

  it "makes no GitHub request and takes no lock" do
    actor
    expect(Github::RequestGate).not_to receive(:hold)
    expect(Github::SourceLock).not_to receive(:acquire)

    dispatch.call(reason: "reconcile")

    expect(WebMock).not_to have_requested(:any, //)
    expect(Github::LockOrder.held_keys).to be_empty
  end
end
