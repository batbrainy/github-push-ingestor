require "rails_helper"

RSpec.describe Github::Status::LedgerState do
  let(:now) { frozen_time }

  describe "an absent row" do
    # Nothing seeds github_api_budget; only a reservation creates it. "No ledger row at
    # all" and "a window whose remaining is genuinely 0" are different facts an operator
    # acts on differently, and present is the boolean that separates them.
    it "reports present false and every other field null" do
      state = described_class.from(nil)

      expect(state.present).to be(false)
      expect(state.to_h.except(:present).values).to all(be_nil)
    end
  end

  describe "a present row" do
    it "projects every per-class counter §11 names" do
      active_budget_window(now: now, poll_used: 7, enrichment_used: 3,
                           actor_share_used: 2, repository_share_used: 1)

      payload = described_class.from(current_budget).payload

      expect(payload).to include(
        present: true, resource: "core", window_status: "active",
        limit: 60, remaining: 55, reserve: 8,
        reset_at: (now + 3600).utc.iso8601,
        poll: { used: 7, allowance: 12 },
        detail_fallback: { used: 3, allowance: 4 },
        actor_requests: { used: 2, guarantee: 2, available: 0 },
        repository_requests: { used: 1, guarantee: 2, available: 1 }
      )
    end

    # Appendix G renames the block for what the number now is: the explicit core
    # detail-fallback allowance, not "everything after poll + reserve". The Search
    # budget is a different rate-limit resource and lives in the search_ledger block.
    it "publishes the allowance as detail_fallback, never as enrichment" do
      active_budget_window(now: now)

      expect(described_class.from(current_budget).payload.keys)
        .not_to include(:enrichment)
      expect(described_class.from(current_budget).payload[:detail_fallback])
        .to eq(used: 0, allowance: 4)
    end

    # available is a floor, not a ceiling: §10 lets one class borrow the other's unspent
    # capacity, which is what takes share_used past the guarantee — a negative number
    # here would read as an accounting error rather than as the borrow it actually is.
    it "floors available at zero, because borrowing takes a class past its guarantee" do
      active_budget_window(now: now, enrichment_used: 4, actor_share_used: 3,
                           repository_share_used: 1)

      expect(described_class.from(current_budget).payload.dig(:actor_requests, :available))
        .to eq(0)
    end

    # Derived from the *stored* enrichment_allowance, never a fresh Allowances.derive:
    # the allowances are fixed at window initialization, and a guarantee recomputed
    # mid-window from a different total could report headroom the ledger would refuse.
    it "splits the guarantees from the stored allowance the ledger enforces" do
      active_budget_window(now: now, enrichment_allowance: 5)

      payload = described_class.from(current_budget).payload

      expect(payload.dig(:actor_requests, :guarantee)).to eq(2)
      expect(payload.dig(:repository_requests, :guarantee)).to eq(3)
    end

    it "keeps the two shares summing to the class counter they were split from" do
      active_budget_window(now: now, enrichment_used: 4,
                           actor_share_used: 3, repository_share_used: 1)
      payload = described_class.from(current_budget).payload

      expect(payload.dig(:actor_requests, :used) + payload.dig(:repository_requests, :used))
        .to eq(payload.dig(:detail_fallback, :used))
    end
  end

  describe "consistency" do
    # Snapshot reads the singleton once and hands the row down — this projection must
    # never issue a query of its own, or two blocks could describe different instants.
    it "issues no query of its own" do
      active_budget_window(now: now)
      budget = current_budget

      expect(capture_sql { described_class.from(budget).payload }).to be_empty
    end
  end
end
