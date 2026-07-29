Rails.application.routes.draw do
  # Health endpoints (IMPLEMENTATION_PLAN.md §11): neither ever calls GitHub
  # or consumes request budget.
  get "/health/live",  to: "health#live"
  get "/health/ready", to: "health#ready"
end
