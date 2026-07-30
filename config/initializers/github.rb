# Startup validation of the request budget (IMPLEMENTATION_PLAN.md §10): the allowance
# formula is computed at startup, and a configuration whose polling requirement leaves
# no capacity for Story 3 enrichment is rejected outright. Raising here stops the
# container rather than letting it poll into an over-commitment.
#
# to_prepare rather than top-level initializer code, because Github::Configuration is
# autoloaded: a bare reference at initializer scope is the classic autoload-during-
# initialization trap and would pin a stale class object across development reloads.
#
# Safe to run before the database exists. Validation touches no database, no network,
# and no schema — it is arithmetic over the environment — so `bin/rails db:prepare`,
# `rails runner`, CI's schema load, and a container starting before the `setup`
# service completes are all unaffected. Every variable has a working default, and the
# default set is feasible (12 + 8 = 20 < 60), so a clean checkout never raises.
Rails.application.config.to_prepare do
  Github.reset!
  Github.configuration.validate!
end
