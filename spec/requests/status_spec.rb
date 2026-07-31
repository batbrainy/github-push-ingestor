require "rails_helper"

RSpec.describe "GET /status", type: :request do
  # §11: "reports persisted state only; never initiates a GitHub request."
  #
  # Four examples rather than one, because the guarantee has four distinct ways to break
  # and each fails silently. They are the pair Github::Ingestion::StateSummary's spec
  # already carries, plus the two that only a controller can get wrong.
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
    it "does not create the ledger row it reports on" do
      expect { get "/status" }.not_to change(GithubApiBudget, :count).from(0)
    end

    # The mirror hazard: reaching for Github::Ingestion::SourceProvisioner to find "the"
    # event source would provision one from a GET.
    it "does not provision the event source it reports on" do
      expect { get "/status" }.not_to change(EventSource, :count).from(0)
    end

    # Belt and braces over the three above: whatever the implementation reaches for, and
    # whatever a future collaborator adds to it, no statement it issues may write.
    it "issues no write statement at all" do
      create_event_source
      create_actor(github_id: 1)
      active_budget_window

      expect(write_statements { get "/status" }).to be_empty
    end
  end

  describe "the response" do
    it "answers 200 with §11's blocks on a clean checkout" do
      get "/status"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.keys)
        .to eq(%w[captured_at sources ledger enrichment coverage])
      expect(response.parsed_body["sources"]).to eq([])
      expect(response.parsed_body.dig("ledger", "present")).to be(false)
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
