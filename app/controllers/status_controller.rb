# IMPLEMENTATION_PLAN.md §11's GET /status: "reports persisted state only; **never
# initiates a GitHub request**."
#
# Structural rather than a promise, the way Github::Ingestion::StateSummary states it: this
# controller holds no executor and no transport, and Github::Status::Snapshot's only
# collaborators are Active Record models and pure values. Github::BudgetLedger is absent by
# construction — all four of its public methods write, and a read path must never create
# the row a reservation owns.
class StatusController < ApplicationController
  # Narrowed to ActiveRecordError rather than StandardError, which is where this departs
  # from HealthController#ready. That action's entire body is one SELECT 1, so every error
  # it can raise really is a database error. Here a bug in the snapshot must surface as a
  # 500 with its backtrace in the JSON log stream, not be laundered into a 503 that tells
  # an operator the database is down. ConnectionNotEstablished, StatementInvalid and
  # NoDatabaseError all descend from this, so the genuine cases are covered.
  #
  # Only the class name crosses the boundary — the same no-internals rule HealthController
  # already holds.
  rescue_from ActiveRecord::ActiveRecordError do |error|
    render json: { status: "unavailable", reason: error.class.name },
           status: :service_unavailable
  end

  # Always 200 while the database answers. A globally blocked ledger, a source out of
  # service and an empty coverage window are the states this endpoint exists to report,
  # not failures of the endpoint — answering 503 for an exhausted rate limit would pull the
  # container out of a load balancer for something /health/live and /health/ready both
  # correctly call healthy.
  #
  # no-store rather than no-cache: a snapshot is true for the instant it was taken, and an
  # intermediary serving a stale ledger to an operator diagnosing a live rate limit is the
  # one failure mode worth spending a header on.
  def show
    response.headers["Cache-Control"] = "no-store"

    render json: Github::Status::Snapshot.capture.payload
  end
end
