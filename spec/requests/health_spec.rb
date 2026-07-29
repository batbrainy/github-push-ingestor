require "rails_helper"

RSpec.describe "Health endpoints", type: :request do
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
