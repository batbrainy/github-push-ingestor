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
# default set is feasible (12 + 40 + 8 = 60), so a clean checkout never raises.
#
# That property is why the *configured* source count is what is validated here and the
# *observed* one is not: ADR 0004 puts deriving ENABLED_LIVE_SOURCE_COUNT from
# event_sources at runtime, in Github::SourceAllocation, precisely so this file keeps
# needing no database. The two log lines below are arithmetic over the same environment
# and preserve it.
Rails.application.config.to_prepare do
  Github.reset!
  configuration = Github.configuration.validate!
  allowances = configuration.allowances

  # §11 puts budget state transitions at INFO, and the numbers a process is about to
  # enforce are the ones every other budget line is read against. One line per boot, so a
  # reviewer tailing `docker compose logs -f` sees the formula's output before the first
  # request rather than having to re-derive it from the environment.
  Rails.logger.info(event: "config.budget_resolved", mode: configuration.mode,
                    poll_interval_seconds: configuration.poll_interval_seconds,
                    max_pages_per_poll: configuration.max_pages_per_poll,
                    enabled_live_source_count: configuration.enabled_live_source_count,
                    worst_case_reservations_per_poll: configuration.worst_case_reservations_per_poll,
                    **allowances.to_log)

  # The over-commitment the allowance formula cannot see. It counts one attempt per page,
  # while §10 makes every retry and every redirect hop its own reservation — so a single
  # failing poll can consume more of the hourly allowance than the formula budgets for the
  # whole cadence.
  #
  # A warning and not a raise, unlike #validate!'s rejection above. That one refuses a
  # certainty: poll_allowance + reserve reaching the limit leaves no enrichment capacity on
  # every single hour, whatever GitHub does. This is a worst case that a healthy endpoint
  # never reaches, and §10 is explicit that runtime conditions must degrade rather than
  # crash-loop the worker. §7 already accepts the underlying trade — "these are
  # request-attempt allowances, not guaranteed successful polls" — so the honest response is
  # to name the exposure, not to refuse to run.
  if configuration.worst_case_reservations_per_poll > allowances.poll_allowance
    Rails.logger.warn(event: "config.amplification",
                      worst_case_reservations_per_poll: configuration.worst_case_reservations_per_poll,
                      poll_allowance: allowances.poll_allowance,
                      max_http_retries: configuration.max_http_retries,
                      max_redirects: configuration.max_redirects,
                      max_pages_per_poll: configuration.max_pages_per_poll)
  end
end
