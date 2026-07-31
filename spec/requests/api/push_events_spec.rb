require "rails_helper"

RSpec.describe "Event inspection API", type: :request do
  let(:actor) { create_actor(github_id: 1001) }
  let(:repository) { create_repository(github_id: 2001) }
  let!(:event) { create_push_event(actor: actor, repository: repository) }

  describe "GET /api/push_events" do
    it "answers 200 with a data array and its paging position" do
      get "/api/push_events"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.keys).to eq(%w[data pagination])
      expect(response.parsed_body["data"].first["id"]).to eq(event.github_event_id)
      expect(response.parsed_body["pagination"])
        .to eq("limit" => 25, "count" => 1, "next_cursor" => nil)
    end

    it "shows each row's enrichment state, which is §16's enrichment gate in a browser" do
      get "/api/push_events"
      row = response.parsed_body["data"].first

      expect(row["actor"]).to include("github_id" => 1001, "login" => "octocat",
                                      "enrichment_status" => "pending")
      expect(row["repository"]).to include("github_id" => 2001,
                                           "enrichment_status" => "pending")
    end

    it "keeps the retained payload out of the list" do
      get "/api/push_events"

      expect(response.parsed_body["data"].first).not_to have_key("raw_payload")
    end

    describe "the Link header" do
      before do
        create_push_event(actor: actor, repository: repository,
                          github_event_id: "40000000002", occurred_at: frozen_time - 60)
      end

      # The emitter and this application's own inbound parser agree, which is the closing
      # symmetry worth asserting: Github::LinkHeader reads GitHub's /events response, and
      # this reads ours.
      it "advertises the next page in the form this application already parses" do
        get "/api/push_events?limit=1"

        next_url = Github::LinkHeader.next_url(response.headers["Link"])

        expect(next_url).to be_present
        expect(next_url).to include("cursor=", "limit=1")
      end

      it "advertises nothing once the last row has been served" do
        get "/api/push_events?limit=25"

        expect(response.headers["Link"]).to be_nil
      end
    end

    describe "parameter validation" do
      it "answers 400 naming the parameter it refused" do
        get "/api/push_events?limit=99999"

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["error"])
          .to eq("code" => "invalid_parameter",
                 "message" => "limit must be an integer from 1 to 100",
                 "parameter" => "limit")
      end

      it "answers 400 for a cursor it did not issue, rather than restarting from the top" do
        get "/api/push_events?cursor=nonsense"

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body.dig("error", "parameter")).to eq("cursor")
      end

      it "answers 400 for an unknown parameter rather than a different question's answer" do
        get "/api/push_events?repo_id=5"

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body.dig("error", "parameter")).to eq("repo_id")
      end
    end
  end

  describe "GET /api/push_events/:id" do
    it "answers 200 with the retained payload, which §16 makes a functional gate" do
      get "/api/push_events/#{event.github_event_id}"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "id")).to eq(event.github_event_id)
      expect(response.parsed_body.dig("data", "raw_payload")).to eq(event.raw_payload)
    end

    # Both identifiers are numeric strings, so :id is genuinely ambiguous and only one
    # reading can be right. github_event_id is the unique index the idempotency story rests
    # on and the identifier §11 puts on every log line — which is what makes "log line ->
    # record" a URL a reviewer can type.
    it "resolves :id as the GitHub event id, never as the surrogate primary key" do
      get "/api/push_events/#{event.id}"
      expect(response).to have_http_status(:not_found)

      get "/api/push_events/#{event.github_event_id}"
      expect(response).to have_http_status(:ok)
    end

    # Without ApplicationController's rescue_from this renders as a DebugExceptions body
    # carrying the exception class and its full backtrace: consider_all_requests_local is
    # true in test and development, and api_only makes that format JSON.
    it "answers 404 with a fixed body, leaking neither internals nor a backtrace" do
      get "/api/push_events/does-not-exist"

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body)
        .to eq("error" => { "code" => "not_found",
                            "message" => "no record matches that identifier" })
    end
  end

  describe "the guarantee that reading events costs nothing (plan §11)" do
    def row_counts
      { push_events: PushEvent.count, actors: GithubActor.count,
        repositories: GithubRepository.count, runs: IngestionRun.count,
        quarantined: QuarantinedEvent.count, budget: GithubApiBudget.count,
        sources: EventSource.count }
    end

    it "initiates no GitHub request" do
      transport = fixture_transport
      allow(Github).to receive(:transport).and_return(transport)
      expect(Github).not_to receive(:executor)

      get "/api/push_events"
      get "/api/push_events/#{event.github_event_id}"

      expect(transport.requests).to be_empty
    end

    it "creates no row, and never bootstraps the ledger it does not read" do
      before_counts = row_counts

      get "/api/push_events"
      get "/api/push_events/#{event.github_event_id}"

      expect(row_counts).to eq(before_counts)
    end

    it "issues no write statement at all" do
      expect(write_statements { get "/api/push_events" }).to be_empty
      expect(write_statements { get "/api/push_events/#{event.github_event_id}" }).to be_empty
    end

    # preload rather than eager_load, and the point of it: the statement count is a
    # function of the page shape, not of the page size.
    it "issues the same statements for fifty rows as for one" do
      50.times do |n|
        create_push_event(actor: actor, repository: repository,
                          github_event_id: "5000000#{format("%04d", n)}",
                          occurred_at: frozen_time - n)
      end

      one = capture_sql { get "/api/push_events?limit=1" }.grep(/\ASELECT/)
      fifty = capture_sql { get "/api/push_events?limit=50" }.grep(/\ASELECT/)

      expect(fifty.length).to eq(one.length)
      expect(fifty.length).to eq(3)
    end
  end
end
