# A ledger row in the state most reservations actually happen in: a window already
# initialized from response headers, with the formula's allowances and nothing spent.
#
# Shared between the ledger's own specs and the executor's, so "what an active window
# looks like" is defined once. Values match the plan's defaults: 60 - 8 - 12 = 40.
module BudgetHelpers
  def active_budget_window(now: frozen_time, **overrides)
    Github::BudgetLedger.new.bootstrap!(now: now)

    GithubApiBudget.where(id: GithubApiBudget::SINGLETON_ID).update_all({
      window_status: "active", window_initialized_at: now,
      limit: 60, remaining: 55, reset_at: now + 3600, observed_at: now,
      poll_allowance: 12, enrichment_allowance: 40, reserve: 8
    }.merge(overrides))

    current_budget
  end

  def current_budget
    GithubApiBudget.find(GithubApiBudget::SINGLETON_ID)
  end
end

RSpec.configure do |config|
  config.include BudgetHelpers
end
