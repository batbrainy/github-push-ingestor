require "rails_helper"

RSpec.describe Github::Status::Snapshot do
  let(:now) { Time.current }

  def payload
    described_class.capture(now: now).payload
  end

  describe "the response shape (plan §11, Appendix G)" do
    it "names every block in the amended order" do
      expect(payload.keys).to eq(%i[captured_at sources ledger search_ledger scheduler
                                    enrichment batches throughput coverage])
    end

    it "answers on a clean checkout without inventing anything" do
      body = payload

      expect(body[:sources]).to eq([])
      expect(body[:ledger][:present]).to be(false)
      expect(body[:search_ledger][:present]).to be(false)
      expect(body[:coverage][:actor_coverage_pct]).to be_nil
      expect(body[:coverage][:event_count]).to eq(0)
      expect(body.dig(:throughput, :catch_up, :state)).to eq("insufficient_sample")
    end

    # The scheduler block is pure configuration, so it is the one block that is fully
    # populated even on a clean checkout — an operator can always read the knobs.
    it "publishes the full scheduler block on a clean checkout" do
      scheduler = payload[:scheduler]

      expect(scheduler.keys).to eq(%i[search fairness core retry refresh metrics])
      expect(scheduler[:search]).to eq(request_ceiling: 10, safety_reserve: 2,
                                       batch_size: 10, pacing_seconds: 6,
                                       worker_concurrency: 1)
      expect(scheduler[:core]).to eq(detail_fallback_allowance: 40, rate_limit_reserve: 8)
    end
  end

  describe "the enrichment counts (plan §11, Appendix G)" do
    it "reports raw statuses, both backlog notions, and the oldest wait" do
      create_actor(github_id: 1, created_at: now - 600)
      create_actor(github_id: 2, login: "two", enrichment_status: "retryable_failure",
                   enrichment_stage: "retry_scheduled", next_retry_at: now + 3600,
                   created_at: now - 300)

      actors = payload.dig(:enrichment, :actors)

      expect(actors).to include(
        pending: 1, retryable_failure: 1,
        backlog_count: 2, contract_backlog_count: 2,
        oldest_pending_at: (now - 600).utc.iso8601,
        oldest_pending_age_seconds: 600
      )
      expect(GithubActor.enrichment_candidates.count).to eq(2)
    end

    it "names every status including the ones with no rows" do
      expected = Enrichable::ENRICHMENT_STATUSES.map(&:to_sym) +
                 %i[backlog_count contract_backlog_count
                    oldest_pending_at oldest_pending_age_seconds stages]

      expect(payload.dig(:enrichment, :actors).keys).to eq(expected)
      expect(payload.dig(:enrichment, :repositories).keys).to eq(expected)
    end

    # The staged-pipeline view: all seven stages, each with its count and its oldest
    # FIFO instant, zeros and nulls kept so a consumer never handles two shapes.
    it "publishes all seven stages with count, oldest instant and age" do
      create_actor(github_id: 1, created_at: now - 900)
      create_actor(github_id: 2, login: "two", enrichment_stage: "detail_pending",
                   detail_pending_at: now - 60, created_at: now - 300)

      stages = payload.dig(:enrichment, :actors, :stages)

      expect(stages.keys).to eq(Enrichable::ENRICHMENT_STAGES.map(&:to_sym))
      expect(stages.each_value.map(&:keys))
        .to all(eq(%i[count oldest_created_at oldest_age_seconds]))
      expect(stages[:batch_pending]).to eq(count: 1,
                                           oldest_created_at: (now - 900).utc.iso8601,
                                           oldest_age_seconds: 900)
      expect(stages[:detail_pending]).to include(count: 1)
      expect(stages[:terminal]).to eq(count: 0, oldest_created_at: nil,
                                      oldest_age_seconds: nil)
    end

    it "counts each class separately, so one cannot mask the other" do
      create_actor(github_id: 1)
      create_repository(github_id: 2, enrichment_status: "permanent_failure",
                        enrichment_stage: "terminal")

      expect(payload.dig(:enrichment, :actors)).to include(pending: 1, permanent_failure: 0,
                                                           backlog_count: 1)
      expect(payload.dig(:enrichment, :repositories)).to include(pending: 0, permanent_failure: 1,
                                                                 backlog_count: 0)
    end
  end

  describe "the ledger blocks (plan §11, Appendix G)" do
    it "distinguishes an absent core row from an exhausted budget" do
      expect(payload[:ledger]).to include(present: false, remaining: nil, reserve: nil)

      active_budget_window(now: now, remaining: 0)

      expect(payload[:ledger]).to include(present: true, remaining: 0, reserve: 8)
    end

    # Appendix G's rename: the core block publishes the explicit detail-fallback
    # allowance; the Search spend is a different resource in its own block beside it.
    it "reports the core detail-fallback budget under its renamed key" do
      active_budget_window(now: now, poll_used: 7, enrichment_used: 3,
                           actor_share_used: 2, repository_share_used: 1)

      expect(payload[:ledger]).to include(
        window_status: "active", resource: "core", limit: 60, remaining: 55,
        poll: { used: 7, allowance: 12 },
        detail_fallback: { used: 3, allowance: 4 },
        actor_requests: { used: 2, guarantee: 2, available: 0 },
        repository_requests: { used: 1, guarantee: 2, available: 1 }
      )
      expect(payload[:ledger].keys).not_to include(:enrichment)
    end

    it "projects the search ledger row beside the core one" do
      active_search_window(now: now, used: 3, actor_used: 2, repository_used: 1,
                           last_request_at: now - 2)

      expect(payload[:search_ledger]).to include(
        present: true, resource: "search", limit: 10, remaining: 9,
        request_ceiling: 10, reserve: 2, spendable: 8, used: 3,
        actor_used: 2, repository_used: 1,
        next_request_earliest_at: (now + 4).utc.iso8601
      )
    end
  end

  describe "the batches and throughput blocks (issue #45)" do
    it "publishes all four batch groups with counted zeros before any batch ran" do
      batches = payload[:batches]

      expect(batches.keys).to eq(%i[window_seconds window_start search detail])
      expect(batches.dig(:search, :actors)).to include(attempts: 0, succeeded: 0,
                                                       fill_ratio: nil)
      expect(batches.dig(:detail, :repositories)).to include(attempts: 0)
    end

    it "aggregates enrichment_batches inside the metrics window" do
      EnrichmentBatch.create!(request_kind: "search", entity_kind: "actor",
                              status: "succeeded", correlation_id: SecureRandom.uuid,
                              started_at: now - 60, requested_count: 10,
                              returned_count: 9, valid_count: 8, missing_count: 1,
                              invalid_count: 1, incomplete_results: false)

      expect(payload.dig(:batches, :search, :actors)).to include(
        attempts: 1, succeeded: 1, requested_items: 10, returned_items: 9,
        valid_items: 8, missing_items: 1, invalid_items: 1, fill_ratio: 0.9,
        incomplete_results_count: 0
      )
    end

    # Throughput is built from the same aggregate the enrichment block reads, so the
    # two can never disagree about the counts they publish side by side.
    it "publishes the catch-up verdict from the shared backlog aggregate" do
      create_actor(github_id: 1, enrichment_status: "complete",
                   enrichment_stage: "contract_complete", created_at: now - 7200,
                   contract_completed_at: now - 60)

      throughput = payload[:throughput]

      expect(throughput[:combined]).to include(arrivals: 0, completions: 1,
                                               backlog_delta: -1)
      expect(throughput.dig(:catch_up, :state)).to eq("keeping_up")
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

    it "reports each source's own latest finished run" do
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

    # §11 asks for the "last run", and the whole reason an operator opens /status is to
    # find out why nothing is moving. Filtering to successes — §9's question, and the one
    # StateSummary's "Latest successful run" line answers — would hide a fresh failure
    # behind an older 200 and show a healthy last_run for a source that had just failed.
    %w[failed deferred].each do |status|
      it "does not hide a fresh #{status} run behind an older success" do
        source = create_event_source
        IngestionRun.create!(event_source: source, started_at: now - 600,
                             completed_at: now - 590, status: "completed")
        newest = IngestionRun.create!(event_source: source, started_at: now - 120,
                                      completed_at: now - 110, status: status)

        expect(payload[:sources].first[:last_run])
          .to eq(run_id: newest.run_id, status: status,
                 completed_at: (now - 110).utc.iso8601)
      end
    end

    it "ignores a run still in flight, which has completed nothing to report" do
      source = create_event_source
      IngestionRun.create!(event_source: source, started_at: now, status: "running")

      expect(payload[:sources].first[:last_run]).to be_nil
    end
  end

  describe "consistency of the snapshot" do
    it "renders every timestamp the way the printed report does" do
      create_event_source(cadence_due_at: now + 300)
      active_budget_window(now: now)
      active_search_window(now: now)
      body = payload

      expect(body[:captured_at]).to eq(now.utc.iso8601)
      expect(body.dig(:ledger, :reset_at)).to eq((now + 3600).utc.iso8601)
      expect(body.dig(:search_ledger, :reset_at)).to eq((now + 60).utc.iso8601)
      expect(body[:sources].first[:next_poll_at]).to eq((now + 300).utc.iso8601)
    end

    it "reads persisted state without writing anything" do
      create_event_source
      create_actor(github_id: 1)
      active_budget_window(now: now)
      active_search_window(now: now)

      expect(write_statements { payload }).to be_empty
    end
  end
end
