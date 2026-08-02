require "rails_helper"

RSpec.describe GithubSearchBudget do
  # No shared builder on purpose: the search row is created by exactly one class in
  # production (Github::SearchBudgetLedger#bootstrap!), and these examples are about
  # the schema surface, so the column defaults are the baseline.
  def create_search_budget(**overrides)
    described_class.create!(overrides)
  end

  it "is stored in a singular table because it holds exactly one row" do
    expect(described_class.table_name).to eq("github_search_budget")
  end

  describe "the singleton constraint" do
    it "defaults the primary key to the singleton id" do
      expect(create_search_budget.id).to eq(described_class::SINGLETON_ID)
    end

    # Enforced in the schema rather than the application, so no process — worker or
    # one-shot — can create a second search ledger to reserve against.
    it "rejects a second row at the database level" do
      create_search_budget

      expect_violation(ActiveRecord::CheckViolation) do
        described_class.connection.execute(<<~SQL.squish)
          INSERT INTO github_search_budget (id, created_at, updated_at)
          VALUES (2, NOW(), NOW())
        SQL
      end

      expect(described_class.count).to eq(1)
    end
  end

  describe "column defaults" do
    it "opens on the configured ceiling and reserve with nothing spent or observed" do
      budget = create_search_budget

      expect(budget).to have_attributes(
        resource: "search", request_ceiling: 10, reserve: 2,
        used: 0, actor_used: 0, repository_used: 0,
        limit: nil, remaining: nil, reset_at: nil, observed_at: nil,
        blocked_until: nil, last_request_at: nil
      )
    end
  end

  describe "counter constraints" do
    it "rejects a negative counter at the database level" do
      budget = create_search_budget

      %i[ reserve used actor_used repository_used ].each do |counter|
        expect_violation(ActiveRecord::CheckViolation) do
          described_class.where(id: budget.id).update_all(counter => -1)
        end
      end
    end

    # A zero ceiling is not a conservative setting: spendable is ceiling - reserve, so
    # zero silently derives a search budget of nothing.
    it "rejects a non-positive ceiling at the database level" do
      budget = create_search_budget

      expect_violation(ActiveRecord::CheckViolation) do
        described_class.where(id: budget.id).update_all(request_ceiling: 0)
      end
    end

    it "rejects a negative header value while permitting an unobserved null" do
      budget = create_search_budget

      %i[ limit remaining ].each do |column|
        expect_violation(ActiveRecord::CheckViolation) do
          described_class.where(id: budget.id).update_all(column => -1)
        end
      end

      expect { budget.update!(limit: nil, remaining: nil) }.not_to raise_error
    end

    it "mirrors the same boundaries as model validations" do
      expect(described_class.new(request_ceiling: 0)).not_to be_valid
      expect(described_class.new(reserve: -1)).not_to be_valid
      expect(described_class.new(used: -1)).not_to be_valid
      expect(described_class.new(actor_used: -1)).not_to be_valid
      expect(described_class.new(repository_used: -1)).not_to be_valid
      expect(described_class.new).to be_valid
    end
  end

  # What the ledger may still spend, from one row: the local ceiling-minus-reserve
  # budget, tightened by GitHub's own remaining when one has been observed.
  describe "#available" do
    it "derives from the local counters alone while remaining is unobserved" do
      expect(create_search_budget(used: 3).available).to eq(5)
    end

    it "reaches zero once the local spendable budget is gone" do
      expect(create_search_budget(used: 8).available).to eq(0)
    end

    it "never goes negative when used has passed the spendable boundary" do
      expect(create_search_budget(used: 9).available).to eq(0)
    end

    it "is bounded by the observed remaining less the reserve" do
      expect(create_search_budget(used: 0, remaining: 4).available).to eq(2)
    end

    it "clamps to zero when the observed remaining is inside the reserve" do
      expect(create_search_budget(used: 0, remaining: 1).available).to eq(0)
    end

    it "never exceeds the local budget however generous the observed remaining" do
      expect(create_search_budget(used: 0, remaining: 100).available).to eq(8)
    end

    it "takes the tighter of the two bounds" do
      expect(create_search_budget(used: 7, remaining: 9).available).to eq(1)
    end
  end

  # One rendering of the row for the structured stream and /status, so the search
  # budget lines cannot describe the same row with different field names.
  describe "#to_log" do
    it "reports the whole search-budget state an operator reads a quiet system against" do
      budget = create_search_budget(
        limit: 10, remaining: 4, reset_at: frozen_time + 60, observed_at: frozen_time,
        used: 3, actor_used: 2, repository_used: 1,
        blocked_until: frozen_time + 120, last_request_at: frozen_time
      )

      expect(budget.to_log).to eq(
        resource: "search", limit: 10, remaining: 4,
        reset_at: "2026-07-29T12:01:00Z", observed_at: "2026-07-29T12:00:00Z",
        request_ceiling: 10, reserve: 2, used: 3, actor_used: 2, repository_used: 1,
        available: 2, blocked_until: "2026-07-29T12:02:00Z",
        last_request_at: "2026-07-29T12:00:00Z"
      )
    end

    # Kept rather than compacted: "remaining is unknown" and "remaining was not
    # reported" are different facts to an operator reading one line.
    it "keeps an unknown value visible instead of dropping the key" do
      expect(create_search_budget.to_log)
        .to include(limit: nil, remaining: nil, reset_at: nil, blocked_until: nil)
    end
  end

  describe "optimistic locking" do
    it "refuses a stale write so concurrent reservations cannot be lost" do
      create_search_budget
      first = described_class.sole
      second = described_class.sole

      first.update!(used: 1)

      expect { second.update!(used: 2) }.to raise_error(ActiveRecord::StaleObjectError)
    end
  end
end
