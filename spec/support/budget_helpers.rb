# Ledger rows in the state most reservations actually happen in.
#
# Shared between the ledgers' own specs and the executors', so "what an active window
# looks like" is defined once. Core values match the plan's Appendix G defaults:
# 12 poll + 4 detail fallback + 8 reserve on the hourly core resource; the search
# window is the per-minute 10-ceiling / 2-reserve pair.
module BudgetHelpers
  def active_budget_window(now: frozen_time, **overrides)
    Github::BudgetLedger.new.bootstrap!(now: now)

    GithubApiBudget.where(id: GithubApiBudget::SINGLETON_ID).update_all({
      window_status: "active", window_initialized_at: now,
      limit: 60, remaining: 55, reset_at: now + 3600, observed_at: now,
      poll_allowance: 12, enrichment_allowance: 4, reserve: 8
    }.merge(overrides))

    current_budget
  end

  def current_budget
    GithubApiBudget.find(GithubApiBudget::SINGLETON_ID)
  end

  # A search-ledger row mid-window: bootstrapped from configuration defaults with the
  # first response's headers already observed. Overrides let a spec spend it down,
  # block it, or start pacing from a chosen instant.
  def active_search_window(now: frozen_time, **overrides)
    Github::SearchBudgetLedger.new(configuration: Github.configuration).bootstrap!(now: now)

    GithubSearchBudget.where(id: GithubSearchBudget::SINGLETON_ID).update_all({
      limit: 10, remaining: 9, reset_at: now + 60, observed_at: now,
      request_ceiling: 10, reserve: 2
    }.merge(overrides))

    current_search_budget
  end

  def current_search_budget
    GithubSearchBudget.find(GithubSearchBudget::SINGLETON_ID)
  end
end

RSpec.configure do |config|
  config.include BudgetHelpers
end
