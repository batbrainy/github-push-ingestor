require "rails_helper"

# The two properties that cannot be observed inside a transaction that never commits.
#
# Under use_transactional_fixtures nothing the suite writes is ever really committed,
# so "the debit is durable before the request is issued" and "the reservation
# serialises on the ledger row" are both invisible to the rest of the suite. This file
# turns transactional tests off to observe them from a genuinely separate PostgreSQL
# session, and pays for that with explicit cleanup.
#
# Cleanup uses around + ensure rather than an after hook: it has to run even when the
# example raises, and it must not depend on hook ordering relative to fixture teardown.
# Under `config.order = :random` a leftover committed row 1 would break every other
# spec's create_budget with a constraint violation, so this cleanup is load-bearing.
RSpec.describe Github::BudgetLedger, "durability" do
  self.use_transactional_tests = false

  subject(:ledger) { described_class.new }

  around do |example|
    example.run
  ensure
    ActiveRecord::Base.connection.execute("DELETE FROM github_api_budget")
    close_second_session
  end

  # §7: a network failure keeps its reservation consumed. That only means anything if
  # the debit reached disk before the socket opened — otherwise a crash mid-request
  # would silently hand the request back while GitHub had already counted it.
  it "commits the debit before the request is issued, so a crash cannot refund it" do
    ledger.reserve!(:poll, now: Time.current)

    committed = second_session.exec("SELECT poll_used FROM github_api_budget WHERE id = 1").getvalue(0, 0)

    expect(committed).to eq("1")
  end

  it "creates the singleton row visibly to other processes, not just to itself" do
    ledger.bootstrap!(now: Time.current)

    expect(second_session.exec("SELECT count(*) FROM github_api_budget").getvalue(0, 0)).to eq("1")
  end

  # Proves the reservation genuinely takes SELECT ... FOR UPDATE, with no threads
  # involved: a second session holds the row, and a short lock_timeout turns "would
  # have blocked here" into a deterministic, typed failure rather than a hang.
  it "serialises the reservation on the ledger row" do
    ledger.bootstrap!(now: Time.current)

    second_session.exec("BEGIN")
    second_session.exec("SELECT * FROM github_api_budget WHERE id = 1 FOR UPDATE")

    begin
      expect {
        ActiveRecord::Base.transaction do
          ActiveRecord::Base.connection.execute("SET LOCAL lock_timeout = '250ms'")
          GithubApiBudget.lock.find(GithubApiBudget::SINGLETON_ID)
        end
      }.to raise_error(ActiveRecord::LockWaitTimeout)
    ensure
      second_session.exec("ROLLBACK")
    end
  end

  # The complement of the guard tested in budget_ledger_spec.rb: with transactional
  # tests off there is no ambient transaction, so a reservation at top level is exactly
  # the production shape and must be allowed.
  it "reserves at top level, which is the shape the executor actually calls it in" do
    expect { ledger.reserve!(:poll, now: Time.current) }.not_to raise_error
  end
end
