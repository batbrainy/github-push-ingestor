require "rails_helper"

RSpec.describe "Health endpoints", type: :request do
  # §16 requires both endpoints to be "meaningful and never consume budget". Meaningful is
  # covered by the examples below — /health/ready really does fail on an unreachable
  # database and on pending migrations. The never-consume half needs its own assertions,
  # because it is the half that fails *silently*: a health check that quietly spent a
  # request would still return 200, and a container healthcheck polls it every few seconds.
  #
  # These mirror spec/requests/status_spec.rb, which pins the same guarantee for /status.
  describe "the guarantee that a health check costs nothing (plan §11)" do
    %w[/health/live /health/ready].each do |path|
      it "initiates no GitHub request from #{path}" do
        transport = fixture_transport
        allow(Github).to receive(:transport).and_return(transport)
        expect(Github).not_to receive(:executor)

        get path

        expect(response).to have_http_status(:ok)
        expect(transport.requests).to be_empty
      end
    end

    # Belt and braces: whatever the implementation reaches for, no statement it issues may
    # write. Github::BudgetLedger#bootstrap! is public and inserts even when it inserts
    # nothing, so a readiness probe that reached for the ledger would create from a health
    # path the very row a reservation owns.
    it "issues no write statement at all" do
      expect(write_statements { get "/health/ready" }).to be_empty
      expect(write_statements { get "/health/live" }).to be_empty
    end

    it "does not create the ledger row or provision an event source" do
      expect { get "/health/ready" }.to not_change(GithubApiBudget, :count).from(0)
        .and not_change(EventSource, :count).from(0)
    end
  end

  describe "GET /health/live" do
    it "reports the process as live" do
      get "/health/live"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("status" => "ok")
    end
  end

  describe "GET /health/ready" do
    it "reports ready when the database is reachable and the schema is current" do
      get "/health/ready"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("status" => "ok")
    end

    it "reports unavailable when the database cannot be reached" do
      allow(ActiveRecord::Base.connection_pool).to receive(:with_connection)
        .and_raise(ActiveRecord::ConnectionNotEstablished)

      get "/health/ready"

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body).to include("status" => "unavailable", "reason" => "ActiveRecord::ConnectionNotEstablished")
    end

    it "reports unavailable when migrations are pending" do
      migration_context = instance_double(ActiveRecord::MigrationContext, needs_migration?: true)
      allow(ActiveRecord::Base.connection_pool).to receive(:migration_context).and_return(migration_context)

      get "/health/ready"

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body).to include("status" => "unavailable", "reason" => "pending migrations")
    end
  end
end
