module Github
  # §10's `ENABLED_LIVE_SOURCE_COUNT`, read from the database instead of from the
  # environment.
  #
  # The allowance formula multiplies the hourly poll count by the number of sources that
  # will actually poll, and until now that number came from an environment variable alone.
  # An operator adding a second event source row and forgetting the variable got a poll
  # allowance provisioned for one source and two sources spending it — twelve attempts an
  # hour split between them, with nothing in the logs saying so. The mirror case is just as
  # quiet: a variable of 3 against a single row reserves 36 poll attempts and leaves
  # enrichment 16 for no reason at all.
  #
  # ADR 0004 committed this to PR 9 by name, and it also fixed *where* it may happen:
  #
  #   "Deriving ENABLED_LIVE_SOURCE_COUNT from event_sources at runtime is PR 9's dynamic
  #    multi-source allocation validation; doing it at boot would reintroduce the database
  #    dependency that keeps validation safe to run before migrations."
  #
  # So config/initializers/github.rb still validates the *configured* number, touching no
  # database, and Github::BudgetLedger asks this class for the observed one at exactly the
  # two moments ADR 0004 already re-derives allowances: window initialization and rollover.
  # That is at most two extra `SELECT count(*)` an hour, not one per reservation.
  #
  # **Lock safety**, since the count runs inside the ledger's `SELECT … FOR UPDATE`
  # transaction. `count` takes only `ACCESS SHARE` on event_sources, which does not conflict
  # with the `SHARE ROW EXCLUSIVE` that Github::Ingestion::SourceProvisioner holds while it
  # creates the first row — so this side never waits. The reverse edge, a session holding an
  # event_sources lock and then reaching for the ledger row, cannot exist either:
  # Github::BudgetLedger#assert_committable! refuses to reserve inside an application
  # transaction at all. No cycle is added to the lock graph.
  class SourceAllocation
    def initialize(configuration: Github.configuration)
      @configuration = configuration
    end

    attr_reader :configuration

    # @param mode [String, Symbol] which adapter's source_type to count. The live and
    #   fixture types are separate rows in the same table — a development database
    #   routinely holds both — and a process only ever polls the one its mode names.
    # @return [Integer] the source count the allowance formula should multiply by
    def live_source_count(mode: configuration.mode)
      observed = observed_count(mode: mode)
      configured = configuration.enabled_live_source_count

      # Zero rows is a fresh install: SourceProvisioner creates the row lazily at the point
      # of use, so the ledger can genuinely be asked before one exists. The configured value
      # is the answer there, not a floor over the observed one — an operator who disabled
      # every source should not have the variable quietly re-enable capacity for them.
      return configured if observed.zero?

      log_drift(observed, configured) unless observed == configured
      observed
    end

    # @return [Integer] rows that will actually be polled, and therefore actually spend
    #   poll allowance. EventSource.pollable is the same predicate EventSource.poll_due
    #   filters on, minus the schedule.
    def observed_count(mode: configuration.mode)
      EventSource.pollable(source_type: EventSources::Base.for_mode(mode).source_type).count
    end

    private

    # WARN rather than INFO, and rather than a raise. It is a real misconfiguration — one of
    # the two numbers is wrong and an operator has to decide which — but §10 forbids
    # crash-looping the worker on a runtime condition, and the derived number is already the
    # safe one to act on. Both poll allowances are named because the drift only matters
    # through its effect on the formula.
    def log_drift(observed, configured)
      Rails.logger.warn(
        event: "budget.source_allocation_drift",
        configured_source_count: configured, observed_source_count: observed,
        configured_poll_allowance: poll_allowance_for(configured),
        observed_poll_allowance: poll_allowance_for(observed)
      )
    end

    def poll_allowance_for(count)
      configuration.allowances(live_source_count: count).poll_allowance
    end
  end
end
