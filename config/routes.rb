Rails.application.routes.draw do
  # Health endpoints (IMPLEMENTATION_PLAN.md §11): neither ever calls GitHub
  # or consumes request budget.
  get "/health/live",  to: "health#live"
  get "/health/ready", to: "health#ready"

  # §11's status endpoint, under the same standing guarantee: reports persisted state only
  # and never initiates a GitHub request, so reading it can never spend budget.
  get "/status", to: "status#show"

  # §11's event inspection API, under that same guarantee.
  #
  # `namespace :api` camelizes to `Api`, not `API`: config/initializers/inflections.rb
  # registers no acronym, so Zeitwerk expects app/controllers/api/.
  #
  # `resources` rather than two explicit `get` lines — unlike the health pair above, this
  # is a genuine REST resource, and it generates the api_push_events_url helper the Link
  # header needs. `only:` is not decoration: it keeps `rails routes` at exactly the two
  # endpoints §11 names, with no create/update/destroy stubs on a read-only surface.
  namespace :api, defaults: { format: :json } do
    resources :push_events, only: %i[index show]
  end
end
