require "rails_helper"

# The one rule both enqueue paths share (§8 steps 10 and 11): "is there durable enrichment
# work this class could do right now?", answered from the committed entity rows and the
# ledger, never from the queue.
RSpec.describe Github::Enrichment::Dispatch do
  subject(:dispatch) { described_class.new(clock: -> { frozen_time }) }

  def actor(**overrides)
    create_actor(github_id: 583_231, last_seen_at: frozen_time, **overrides)
  end

  def repository(**overrides)
    create_repository(github_id: 1_296_269, last_seen_at: frozen_time, **overrides)
  end

  before { active_budget_window(now: frozen_time) }

  describe "when a class has work" do
    it "enqueues one cycle for each class that does, and none for the class that does not" do
      actor

      expect { dispatch.call(reason: "reconcile") }
        .to have_enqueued_job(EnrichActorJob).exactly(:once)
      expect(ActiveJob::Base.queue_adapter.enqueued_jobs.map { _1[:job] }).to eq([ EnrichActorJob ])
    end

    # However deep the backlog. Github::EnrichmentRunner enriches at most one entity per call,
    # so queue depth is set by §10's hourly allowance and not by how many rows are waiting —
    # 90 pending actors would otherwise become 90 cycles the ledger refuses 40 requests in.
    it "enqueues one cycle whether one entity is pending or fifty" do
      50.times { |index| create_actor(github_id: 1_000 + index, last_seen_at: frozen_time) }

      expect { dispatch.call(reason: "reconcile") }.to have_enqueued_job(EnrichActorJob).exactly(:once)
    end

    it "reports what it scheduled" do
      actor
      repository

      expect(dispatch.call(reason: "ingestion"))
        .to eq(actor_enqueued: 1, repository_enqueued: 1, reason: "ingestion")
    end

    # §11 lists "reconciliation summaries" among the INFO events, and PR 7's Summary is what
    # fills it — per-status counts, per-class share usage, the window state.
    it "logs the summary at INFO, because a tick that scheduled work is worth reading" do
      actor
      allow(Rails.logger).to receive(:info)

      dispatch.call(reason: "reconcile")

      expect(Rails.logger).to have_received(:info).with(
        hash_including(event: "enrichment.dispatched", reason: "reconcile", actor_enqueued: 1,
                       enrichment_used: 0, enrichment_allowance: 40, window_status: "active")
      )
    end
  end

  describe "when there is nothing to do" do
    it "enqueues nothing when every entity is decided" do
      actor(enrichment_status: "complete", fetched_at: frozen_time)
      repository(enrichment_status: "permanent_failure")

      expect { dispatch.call(reason: "reconcile") }.not_to have_enqueued_job
    end

    # An entity another worker is mid-way through is not pending work: the claim lease lives
    # on next_retry_at, and every one of the selector's queries excludes it.
    it "enqueues nothing while the only candidate is leased by a live worker" do
      actor
      GithubActor.update_all(next_retry_at: frozen_time + 600)

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

  # §9's effective_enrichment_time, minus the entity component this object is not choosing.
  describe "when the ledger says enrichment cannot happen" do
    it "enqueues nothing while a global block is in force, and names it" do
      actor
      active_budget_window(now: frozen_time, global_blocked_until: frozen_time + 300)

      expect { dispatch.call(reason: "reconcile") }.not_to have_enqueued_job
      expect(dispatch.call(reason: "reconcile")).to include(blocked_by: :global_blocked_until)
    end

    it "enqueues nothing once the enrichment class has spent its allowance" do
      actor
      active_budget_window(now: frozen_time, enrichment_used: 40, reset_at: frozen_time + 600)

      expect { dispatch.call(reason: "reconcile") }.not_to have_enqueued_job
      expect(dispatch.call(reason: "reconcile")).to include(blocked_by: :enrichment_class_blocked_until)
    end

    # §10: a share exhaustion is a *denial* relieved by borrowing, not a deferral. Refusing to
    # enqueue on it would withhold work the ledger would have granted — the reason
    # Github::EnrichmentSchedule leaves the share out too.
    it "still enqueues when only one class's fairness share is spent" do
      actor
      active_budget_window(now: frozen_time, actor_share_used: 20, enrichment_used: 20)

      expect { dispatch.call(reason: "reconcile") }.to have_enqueued_job(EnrichActorJob)
    end
  end

  # A clean checkout has no ledger row: nothing seeds it, and only a reservation inside the
  # request gate creates one. Reading a schedule must not.
  describe "before the first window exists" do
    it "enqueues without creating the ledger row" do
      GithubApiBudget.delete_all
      actor

      expect { dispatch.call(reason: "ingestion") }.to have_enqueued_job(EnrichActorJob)
      expect(GithubApiBudget.count).to eq(0)
    end
  end

  it "makes no GitHub request and takes no lock" do
    actor
    expect(Github::RequestGate).not_to receive(:hold)

    dispatch.call(reason: "reconcile")

    expect(WebMock).not_to have_requested(:any, //)
  end
end
