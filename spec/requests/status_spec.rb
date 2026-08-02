require "rails_helper"

RSpec.describe "GET /status", type: :request do
  # §11: "reports persisted state only; never initiates a GitHub request."
  #
  # Five examples rather than one, because the guarantee has distinct ways to break and
  # each fails silently. They are the pair Github::Ingestion::StateSummary's spec
  # already carries, plus the ones only a controller can get wrong — now including the
  # Search ledger, whose bootstrap! would create its configuration-born row from a GET.
  describe "the guarantee that reading state costs nothing (plan §11)" do
    it "initiates no GitHub request" do
      transport = fixture_transport
      allow(Github).to receive(:transport).and_return(transport)
      expect(Github).not_to receive(:executor)

      get "/status"

      expect(response).to have_http_status(:ok)
      expect(transport.requests).to be_empty
    end

    # The subtle one: Github::BudgetLedger#bootstrap! is public and issues an INSERT even
    # when it inserts nothing, so reaching for the ledger instead of find_by would create
    # from a read path the very row a reservation owns.
    it "does not create the core ledger row it reports on" do
      expect { get "/status" }.not_to change(GithubApiBudget, :count).from(0)
    end

    # The same hazard one table over: Github::SearchBudgetLedger#bootstrap! creates the
    # search row from configuration, so a read path reaching it would make /status the
    # first "search request" the installation ever recorded.
    it "does not create the search ledger row it reports on" do
      expect { get "/status" }.not_to change(GithubSearchBudget, :count).from(0)
    end

    # The mirror hazard: reaching for Github::Ingestion::SourceProvisioner to find "the"
    # event source would provision one from a GET.
    it "does not provision the event source it reports on" do
      expect { get "/status" }.not_to change(EventSource, :count).from(0)
    end

    # Belt and braces over the four above, now proven across the staged-enrichment
    # tables too: whatever the implementation reaches for, and whatever a future
    # collaborator adds to it, no statement it issues may write.
    it "issues no write statement at all" do
      create_event_source
      create_actor(github_id: 1)
      create_actor(github_id: 2, login: "two", enrichment_stage: "detail_pending",
                   detail_pending_at: Time.current - 60)
      active_budget_window
      active_search_window
      EnrichmentBatch.create!(request_kind: "search", entity_kind: "actor",
                              status: "succeeded", correlation_id: SecureRandom.uuid,
                              started_at: Time.current - 60, requested_count: 1,
                              returned_count: 1, valid_count: 1)

      expect(write_statements { get "/status" }).to be_empty
    end
  end

  describe "the response" do
    it "answers 200 with the amended §11 blocks on a clean checkout" do
      get "/status"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.keys)
        .to eq(%w[captured_at sources ledger search_ledger scheduler enrichment
                  batches throughput coverage])
      expect(response.parsed_body["sources"]).to eq([])
      expect(response.parsed_body.dig("ledger", "present")).to be(false)
      expect(response.parsed_body.dig("search_ledger", "present")).to be(false)
      expect(response.parsed_body.dig("throughput", "catch_up", "state"))
        .to eq("insufficient_sample")
    end

    # The scheduler block is pure configuration — the one block a clean checkout can
    # and must answer in full, so an operator can always read the enforced knobs.
    it "publishes the full scheduler block on a clean checkout" do
      get "/status"

      scheduler = response.parsed_body["scheduler"]

      expect(scheduler.keys).to eq(%w[search fairness core retry refresh metrics])
      expect(scheduler["search"])
        .to eq("request_ceiling" => 10, "safety_reserve" => 2, "batch_size" => 10,
               "pacing_seconds" => 6, "worker_concurrency" => 1)
      expect(scheduler["core"])
        .to eq("detail_fallback_allowance" => 4, "rate_limit_reserve" => 8)
      expect(scheduler["metrics"])
        .to eq("window_seconds" => 3600, "catch_up_min_sample_seconds" => 900)
    end

    it "publishes the staged pipeline for each entity class" do
      create_actor(github_id: 1, created_at: Time.current - 600)

      get "/status"

      actors = response.parsed_body.dig("enrichment", "actors")

      expect(actors).to include("pending" => 1, "backlog_count" => 1,
                                "contract_backlog_count" => 1)
      expect(actors["stages"].keys).to eq(Enrichable::ENRICHMENT_STAGES)
      expect(actors.dig("stages", "batch_pending")).to include("count" => 1)
      expect(actors.dig("stages", "terminal"))
        .to eq("count" => 0, "oldest_created_at" => nil, "oldest_age_seconds" => nil)
    end

    # A snapshot is true for the instant it was taken. An intermediary serving a stale
    # ledger to an operator diagnosing a live rate limit is the failure this prevents.
    it "forbids caching, because a snapshot goes stale immediately" do
      get "/status"

      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    # These are the states the endpoint exists to report, not failures of the endpoint.
    # A 503 here would pull the container out of a load balancer for something both health
    # endpoints correctly call healthy.
    it "answers 200 for a globally blocked ledger and an out-of-service source" do
      active_budget_window(window_status: "globally_blocked",
                           global_blocked_until: Time.current + 300)
      create_event_source(status: "failed")

      get "/status"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("ledger", "window_status")).to eq("globally_blocked")
      expect(response.parsed_body["sources"].first["status"]).to eq("failed")
    end

    # The populated catch-up story: rows that arrived before the metrics window and
    # completed inside it are pure drain, so the counted backlog slope is negative and
    # the verdict is keeping_up — measured numbers, no ETA anywhere.
    it "reports keeping_up with a negative backlog delta after completions drain the window" do
      now = Time.current
      create_actor(github_id: 1001, created_at: now - 7200,
                   enrichment_status: "complete", enrichment_stage: "contract_complete",
                   contract_completed_at: now - 120, fetched_at: now - 120)
      create_repository(github_id: 2001, created_at: now - 7200,
                        enrichment_status: "complete", enrichment_stage: "contract_complete",
                        contract_completed_at: now - 60, fetched_at: now - 60)

      get "/status"

      throughput = response.parsed_body["throughput"]

      expect(throughput["combined"]).to include("arrivals" => 0, "completions" => 2,
                                                "exits" => 2, "backlog_delta" => -2)
      expect(throughput.dig("catch_up", "state")).to eq("keeping_up")
      expect(response.parsed_body.dig("enrichment", "actors", "complete")).to eq(1)
    end

    it "reports coverage over persisted events, joined to their entities" do
      actor = create_actor(github_id: 1001)
      repository = create_repository(github_id: 2001)
      actor.update!(enrichment_status: "complete", fetched_at: Time.current)
      create_push_event(actor: actor, repository: repository)

      get "/status"

      expect(response.parsed_body["coverage"]).to include(
        "basis" => "created_at", "event_count" => 1,
        "actor_coverage_pct" => 100.0, "repository_coverage_pct" => 0.0,
        "events_with_both_entities_enriched_pct" => 0.0
      )
    end
  end

  describe "when the database cannot answer" do
    it "degrades to 503 without leaking internals" do
      allow(Github::Status::Snapshot).to receive(:capture)
        .and_raise(ActiveRecord::ConnectionNotEstablished)

      get "/status"

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body)
        .to eq("status" => "unavailable", "reason" => "ActiveRecord::ConnectionNotEstablished")
    end
  end
end
