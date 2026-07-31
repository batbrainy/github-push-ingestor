# §11 places one guarantee on every health and inspection endpoint: they report persisted
# state and never initiate a GitHub request. Github::Ingestion::StateSummary states the
# corollary its own specs pin — a read path must also not *write*, because the subtle
# version of the mistake is calling Github::BudgetLedger#bootstrap! and creating the very
# row a reservation owns.
#
# Counting rows before and after catches that only for tables a spec thought to count.
# Subscribing to the statements themselves catches it for every table, including the ones
# a future collaborator introduces.
module SqlHelpers
  # Rails wraps each example in a transaction and emits savepoint statements around
  # anything using requires_new, so those are not writes to the business tables and must
  # not be reported as such. TRANSACTION-payload events (BEGIN/COMMIT) carry no :sql in
  # some adapters, hence the guard.
  WRITE = /\A\s*(INSERT|UPDATE|DELETE|TRUNCATE|CREATE|ALTER|DROP)\b/i

  def capture_sql
    statements = []

    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] if payload[:sql].present?
    end

    yield

    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def write_statements(&block)
    capture_sql(&block).grep(WRITE)
  end
end

RSpec.configure do |config|
  config.include SqlHelpers
end
