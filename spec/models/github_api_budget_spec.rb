require "rails_helper"

RSpec.describe GithubApiBudget do
  it "is stored in a singular table because it holds exactly one row" do
    expect(described_class.table_name).to eq("github_api_budget")
  end

  describe "the singleton constraint" do
    it "defaults the primary key to the singleton id" do
      expect(create_budget.id).to eq(described_class::SINGLETON_ID)
    end

    # Enforced in the schema rather than the application, so no process — poller,
    # worker, or one-shot — can create a second ledger to reserve against (§7).
    it "rejects a second row at the database level" do
      create_budget

      expect_violation(ActiveRecord::CheckViolation) do
        described_class.connection.execute(<<~SQL.squish)
          INSERT INTO github_api_budget (id, created_at, updated_at)
          VALUES (2, NOW(), NOW())
        SQL
      end

      expect(described_class.count).to eq(1)
    end
  end

  describe "window state" do
    it "starts uninitialized, so enrichment is ineligible until a poll bootstraps it" do
      budget = create_budget

      expect(budget.window_status).to eq("uninitialized")
      expect(budget.limit).to be_nil
      expect(budget.remaining).to be_nil
      expect(budget.reset_at).to be_nil
    end

    it "accepts every documented window status" do
      budget = create_budget

      described_class::WINDOW_STATUSES.each do |status|
        budget.update!(window_status: status)
        expect(budget.reload.window_status).to eq(status)
      end
    end

    it "rejects an undocumented window status at the database level" do
      budget = create_budget

      expect_violation(ActiveRecord::CheckViolation) do
        described_class.where(id: budget.id).update_all(window_status: "invented")
      end
    end
  end

  describe "class counters" do
    it "start at zero so a fresh window has nothing spent" do
      budget = create_budget

      described_class::COUNTERS.each do |counter|
        expect(budget.public_send(counter)).to eq(0), "expected #{counter} to default to 0"
      end
    end

    it "rejects a negative counter at the database level" do
      budget = create_budget

      described_class::COUNTERS.each do |counter|
        expect_violation(ActiveRecord::CheckViolation) do
          described_class.where(id: budget.id).update_all(counter => -1)
        end
      end
    end

    it "rejects a negative header value" do
      budget = create_budget

      %i[limit remaining].each do |column|
        expect_violation(ActiveRecord::CheckViolation) do
          described_class.where(id: budget.id).update_all(column => -1)
        end
      end
    end

    # Reservation arithmetic (used <= allowance, reserve headroom) is deliberately not
    # constrained here — PR 4's BudgetLedger owns it.
    it "permits usage above the current allowance, which the ledger reconciles" do
      budget = create_budget

      expect { budget.update!(poll_allowance: 12, poll_used: 20) }.not_to raise_error
    end
  end

  describe "optimistic locking" do
    it "refuses a stale write so concurrent reservations cannot be lost" do
      create_budget
      first = described_class.sole
      second = described_class.sole

      first.update!(poll_used: 1)

      expect { second.update!(poll_used: 2) }.to raise_error(ActiveRecord::StaleObjectError)
    end
  end

  describe "derived class blocking" do
    # Plan §10: one timestamp cannot serve both. Class blocking is derived from the
    # counters so that enrichment exhausting its allowance never stops polling.
    it "stores no per-class block timestamp" do
      expect(described_class.column_names.grep(/class_blocked/)).to be_empty
    end

    it "stores only the global block" do
      expect(described_class.column_names).to include("global_blocked_until")
    end
  end
end
