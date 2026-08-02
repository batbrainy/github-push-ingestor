require "rails_helper"

RSpec.describe Github::Status::SearchLedgerState do
  let(:now) { frozen_time }

  describe "an absent row" do
    # Unlike core, the search row is configuration-born: it appears with the first
    # search reservation, so a clean checkout legitimately has none. present is the
    # one boolean that separates "no row" from "a row with unknown counters".
    it "reports present false and every other field null" do
      state = described_class.from(nil, now: now)

      expect(state.present).to be(false)
      expect(state.to_h.except(:present).values).to all(be_nil)
    end

    it "keeps the payload's fixed key set with nulls, never missing keys" do
      payload = described_class.from(nil, now: now).payload

      expect(payload.keys).to eq(%i[present resource limit remaining reset_at
                                    observed_at request_ceiling reserve spendable used
                                    actor_used repository_used available blocked_until
                                    last_request_at next_request_earliest_at])
      expect(payload).to include(present: false, spendable: nil,
                                 next_request_earliest_at: nil)
    end
  end

  describe "a present row" do
    it "projects every column plus the derived spendable ceiling" do
      active_search_window(now: now, used: 3, actor_used: 2, repository_used: 1)

      state = described_class.from(current_search_budget, now: now)

      expect(state).to have_attributes(
        present: true, resource: "search", limit: 10, remaining: 9,
        reset_at: now + 60, observed_at: now, request_ceiling: 10, reserve: 2,
        spendable: 8, used: 3, actor_used: 2, repository_used: 1,
        blocked_until: nil, last_request_at: nil, next_request_earliest_at: nil
      )
      expect(state.available).to eq(current_search_budget.available)
    end

    # spendable is the fixed ceiling-minus-reserve pair, not the headroom left — the
    # headroom is `available` beside it, and publishing both makes the spend checkable.
    it "keeps spendable constant however much has been spent" do
      active_search_window(now: now, used: 9)

      expect(described_class.from(current_search_budget, now: now).spendable).to eq(8)
    end

    it "renders every timestamp the way the printed report does" do
      active_search_window(now: now, last_request_at: now - 2, blocked_until: now + 30)

      payload = described_class.from(current_search_budget, now: now).payload

      expect(payload).to include(
        reset_at: (now + 60).utc.iso8601,
        observed_at: now.utc.iso8601,
        last_request_at: (now - 2).utc.iso8601,
        blocked_until: (now + 30).utc.iso8601
      )
    end
  end

  describe "#next_request_earliest_at" do
    it "names the pacing resume after a recent request" do
      active_search_window(now: now, last_request_at: now - 2)

      expect(described_class.from(current_search_budget, now: now)
        .next_request_earliest_at).to eq(now + 4)
    end

    it "lets a block outlast pacing when it ends later" do
      active_search_window(now: now, last_request_at: now - 2, blocked_until: now + 30)

      expect(described_class.from(current_search_budget, now: now)
        .next_request_earliest_at).to eq(now + 30)
    end

    it "lets pacing outlast a block about to expire" do
      active_search_window(now: now, last_request_at: now - 2, blocked_until: now + 1)

      expect(described_class.from(current_search_budget, now: now)
        .next_request_earliest_at).to eq(now + 4)
    end

    # null means "a request is permitted right now" — an instant in the past would
    # force every consumer to compare against its own clock to learn the same fact.
    it "is null once pacing and any block have both cleared" do
      active_search_window(now: now, last_request_at: now - 10, blocked_until: now - 5)

      expect(described_class.from(current_search_budget, now: now)
        .next_request_earliest_at).to be_nil
    end

    it "paces from the configuration it was given" do
      active_search_window(now: now, last_request_at: now - 2)
      configuration = configuration_with(SEARCH_PACING_SECONDS: "10")

      state = described_class.from(current_search_budget, configuration: configuration,
                                                          now: now)

      expect(state.next_request_earliest_at).to eq(now + 8)
    end
  end

  describe "consistency" do
    # Snapshot reads the singleton once and hands the row down — this projection must
    # never issue a query of its own, or two blocks could describe different instants.
    it "issues no query of its own" do
      active_search_window(now: now)
      budget = current_search_budget

      expect(capture_sql { described_class.from(budget, now: now).payload }).to be_empty
    end
  end
end
