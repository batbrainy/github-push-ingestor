require "rails_helper"

RSpec.describe Github::Status::Snapshot do
  let(:now) { Time.current }

  def payload
    described_class.capture(now: now).payload
  end

  describe "the response shape (plan §11)" do
    it "names every block §11 asks for, in §11's order" do
      expect(payload.keys).to eq(%i[captured_at sources ledger enrichment coverage])
    end

    it "answers on a clean checkout without inventing anything" do
      body = payload

      expect(body[:sources]).to eq([])
      expect(body[:ledger][:present]).to be(false)
      expect(body[:coverage][:actor_coverage_pct]).to be_nil
      expect(body[:coverage][:event_count]).to eq(0)
    end
  end

  describe "the enrichment counts (plan §11)" do
    # The example that keeps two numbers from silently becoming one. §11's
    # pending_actor_count sits beside skipped_actor_count, so it means the *status*;
    # Github::Ingestion::StateSummary uses the same name for the enrichment_candidates
    # scope, which is pending plus retryable_failure. Both are right for their own
    # question. Publishing both under distinct names is what makes them checkable.
    it "reports pending as the status and the candidate scope under its own name" do
      create_actor(github_id: 1)
      create_actor(github_id: 2, login: "two", enrichment_status: "retryable_failure")

      actors = payload.dig(:enrichment, :actors)

      expect(actors).to include(pending: 1, retryable_failure: 1, candidates: 2)
      expect(GithubActor.enrichment_candidates.count).to eq(2)
      expect(Github::Ingestion::StateSummary.capture(now: now).pending_actor_count).to eq(2)
    end

    it "names every status including the ones with no rows" do
      expected = Enrichable::ENRICHMENT_STATUSES.map(&:to_sym) + [ :candidates ]

      expect(payload.dig(:enrichment, :actors).keys).to eq(expected)
      expect(payload.dig(:enrichment, :repositories).keys).to eq(expected)
    end

    it "counts each class separately, so one cannot mask the other" do
      create_actor(github_id: 1)
      create_repository(github_id: 2, enrichment_status: "skipped_budget")

      expect(payload.dig(:enrichment, :actors)).to include(pending: 1, skipped_budget: 0)
      expect(payload.dig(:enrichment, :repositories)).to include(pending: 0, skipped_budget: 1)
    end
  end

  describe "the ledger block (plan §11)" do
    it "distinguishes an absent row from an exhausted budget" do
      expect(payload[:ledger]).to include(present: false, remaining: nil, reserve: nil)

      active_budget_window(now: now, remaining: 0)

      expect(payload[:ledger]).to include(present: true, remaining: 0, reserve: 8)
    end

    it "reports every per-class counter §11 names" do
      active_budget_window(now: now, poll_used: 7, enrichment_used: 23,
                           actor_share_used: 9, repository_share_used: 14)

      expect(payload[:ledger]).to include(
        window_status: "active", resource: "core", limit: 60, remaining: 55,
        poll: { used: 7, allowance: 12 },
        enrichment: { used: 23, allowance: 40 },
        actor_requests: { used: 9, guarantee: 20, available: 11 },
        repository_requests: { used: 14, guarantee: 20, available: 6 }
      )
    end

    # available is the headroom inside a guarantee, and §10 lets a class borrow past it
    # when the other has no eligible candidate. A negative number here would read as an
    # accounting error rather than as the borrow it actually is.
    it "floors available at zero, because borrowing takes a class past its guarantee" do
      active_budget_window(now: now, actor_share_used: 26)

      expect(payload.dig(:ledger, :actor_requests))
        .to eq(used: 26, guarantee: 20, available: 0)
    end

    it "keeps the two shares summing to the class counter it was split from" do
      active_budget_window(now: now, enrichment_used: 23,
                           actor_share_used: 9, repository_share_used: 14)
      ledger = payload[:ledger]

      expect(ledger.dig(:actor_requests, :used) + ledger.dig(:repository_requests, :used))
        .to eq(ledger.dig(:enrichment, :used))
    end
  end

  describe "the poll block (plan §11)" do
    it "reports no sources rather than a null one on a clean checkout" do
      expect(payload[:sources]).to eq([])
    end

    # StateSummary picks EventSource.order(:id).first because §9's one-shot runs one
    # command against one source. /status describes the installation, and the README's
    # reviewer path routinely leaves two rows in the database — so a singular pick would
    # name whichever was created first, quite possibly not the one running.
    it "reports one entry per source, ordered by id" do
      live = create_event_source
      fixture = create_event_source(source_type: "github_fixture_events")

      expect(payload[:sources].map { |source| source[:id] }).to eq([ live.id, fixture.id ])
      expect(payload[:sources].map { |source| source[:source_type] })
        .to eq(%w[github_public_events github_fixture_events])
    end

    it "names every scheduling component, and only the ones in play carry an instant" do
      create_event_source(cadence_due_at: now + 300, poll_floor_until: now + 60)
      source = payload[:sources].first

      expect(source[:scheduling_components].keys).to eq(Github::PollSchedule::COMPONENTS)
      expect(source[:scheduling_components]).to include(
        cadence_due_at: (now + 300).utc.iso8601,
        poll_floor_until: (now + 60).utc.iso8601,
        retry_not_before_at: nil, global_blocked_until: nil, poll_class_blocked_until: nil
      )
      expect(source[:binding_component]).to eq(:cadence_due_at)
      expect(source[:next_poll_at]).to eq((now + 300).utc.iso8601)
      expect(source[:due_now]).to be(false)
    end

    # nil here means "no constraint applies", not "unknown" — and JSON cannot say which
    # without being told, which is what due_now is for.
    it "says a source with nothing holding it back is due now" do
      create_event_source

      expect(payload[:sources].first)
        .to include(due_now: true, next_poll_at: nil, binding_component: nil)
    end

    it "surfaces a source taken out of service, which nothing else exposes over HTTP" do
      create_event_source(status: "failed", consecutive_failures: 3, last_error: "410 Gone")

      expect(payload[:sources].first)
        .to include(status: "failed", enabled: true, consecutive_failures: 3)
    end

    it "reports each source's own latest successful run" do
      first = create_event_source
      second = create_event_source(source_type: "github_fixture_events")
      IngestionRun.create!(event_source: first, started_at: now - 600, completed_at: now - 590,
                           status: "completed")
      newest = IngestionRun.create!(event_source: first, started_at: now - 120,
                                    completed_at: now - 110, status: "not_modified")

      runs = payload[:sources].map { |source| source[:last_run] }

      expect(runs.first).to eq(run_id: newest.run_id, status: "not_modified",
                               completed_at: (now - 110).utc.iso8601)
      expect(runs.second).to be_nil
      expect(second.reload).to be_present
    end

    it "ignores a run still in flight, which has completed nothing to report" do
      source = create_event_source
      IngestionRun.create!(event_source: source, started_at: now, status: "running")

      expect(payload[:sources].first[:last_run]).to be_nil
    end
  end

  describe "consistency of the snapshot" do
    # The reason this is one aggregate rather than StateSummary and Summary side by side.
    # Three independent reads could straddle a committing reservation and produce a body
    # whose poll block contradicts its ledger block.
    it "reads the ledger row exactly once" do
      active_budget_window(now: now)
      allow(GithubApiBudget).to receive(:find_by).and_call_original

      described_class.capture(now: now).payload

      expect(GithubApiBudget).to have_received(:find_by).once
    end

    it "renders every timestamp the way the printed report does" do
      create_event_source(cadence_due_at: now + 300)
      active_budget_window(now: now)
      body = payload

      expect(body[:captured_at]).to eq(now.utc.iso8601)
      expect(body.dig(:ledger, :reset_at)).to eq((now + 3600).utc.iso8601)
      expect(body[:sources].first[:next_poll_at]).to eq((now + 300).utc.iso8601)
    end
  end
end
