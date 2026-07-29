class HealthController < ApplicationController
  # Liveness: the process is up and serving requests. Never touches the
  # database, never calls GitHub, never consumes budget (plan §11).
  def live
    render json: { status: "ok" }
  end

  # Readiness: the primary database is reachable and the schema is current.
  # Same no-GitHub, no-budget guarantee as liveness.
  def ready
    ActiveRecord::Base.connection_pool.with_connection { |connection| connection.execute("SELECT 1") }

    if ActiveRecord::Base.connection_pool.migration_context.needs_migration?
      render json: { status: "unavailable", reason: "pending migrations" }, status: :service_unavailable
    else
      render json: { status: "ok" }
    end
  rescue StandardError => e
    render json: { status: "unavailable", reason: e.class.name }, status: :service_unavailable
  end
end
