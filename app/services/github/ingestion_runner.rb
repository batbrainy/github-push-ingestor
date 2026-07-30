module Github
  # One polling operation, end to end (IMPLEMENTATION_PLAN.md §5, §8 steps 1–9, §9).
  #
  # §5 names this component and says what it owns: "IngestionRunner owns the source lock
  # for the duration of a polling operation. RequestExecutor does not own or acquire
  # SourceLock — its chain begins at the request gate and is identical for polling and
  # enrichment."
  #
  # The sequence, and the orderings that are load-bearing:
  #
  #   1. acquire the source lock                                     §8 step 1
  #   2. re-read the source and decide whether a poll is due at all   §9
  #   3. open the ingestion_runs row — inside the lock, so Errors::SourceBusy provably
  #      cannot leave a stray running row behind
  #   4. walk the pages through Github.executor                      §8 step 2
  #   5. persist poll state and finalize the run row
  #
  # Step 2 is inside the lock, not before it, and it re-reads the row. The caller's
  # EventSource was loaded before mutual exclusion existed — SourceProvisioner.ensure!
  # runs first in the one-shot — so two processes starting together would both see
  # cadence_due_at as it was, both decide they were due, serialize on the lock, and poll
  # back to back. Reading committed state under the lock is what makes the lock's
  # guarantee real rather than nominal.
  #
  # **A not-due attempt opens no ingestion_runs row.** §7 calls that row "one polling
  # cycle" and no cycle happened: no request, no reservation, no page. PR 5's vocabulary
  # defines `deferred` as a request that never happened for a reason discovered *after*
  # RequestExecutor ran — a budget denial, a held gate, a rate-limit response — and "we
  # chose not to ask" is a different fact. The rule that falls out is easy to hold: **a run
  # row exists iff the process tried to reach GitHub.** It matters most under PR 8's
  # recurring task, where a row per tick against a five-minute cadence would be dozens of
  # zero-count rows an hour diluting every counter in the table.
  #
  # This class opens no transaction of its own. Every write it makes is a single statement
  # or a delegation, and none of them ever encloses a call to the executor: BudgetLedger
  # refuses a reservation inside an open application transaction, because an outer
  # rollback would refund a request GitHub has already counted.
  #
  # It still enqueues nothing. §8 step 10 is PR 8, and §8 already says why no list of
  # created ids is needed: "the committed entity state is the durable record of pending
  # work (outbox-style recovery)" — and the enrichment_candidates partial index for
  # exactly that predicate already exists.
  class IngestionRunner
    MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

    # One return type for every outcome, the same philosophy RequestExecutor#call applies
    # to requests: a caller branches once instead of rescuing four classes and eventually
    # missing one.
    class Result < Data.define(:run_id, :status, :tally, :classification, :last_error,
                               :deferral_reason, :next_poll_at)
      # Members default, so a caller constructing a Result by hand is not broken by one it
      # does not care about — the same reason Github::Request overrides initialize.
      def initialize(run_id:, status:, tally: Ingestion::Tally.empty, classification: nil,
                     last_error: nil, deferral_reason: nil, next_poll_at: nil)
        super
      end

      def completed? = status == "completed"
      def not_modified? = status == "not_modified"
      def deferred? = status == "deferred"
      def failed? = status == "failed"

      def to_log
        { run_status: status, classification: classification, deferral_reason: deferral_reason,
          next_poll_at: next_poll_at&.utc&.iso8601, error_message: last_error }
          .compact.merge(tally.to_log)
      end
    end

    def initialize(executor: Github.executor, writer: Ingestion::PageWriter.new,
                   configuration: Github.configuration, clock: -> { Time.current },
                   monotonic: MONOTONIC, rate_limit_policy: RateLimitPolicy.new,
                   page_loop: nil, poll_state: nil)
      @configuration = configuration
      @clock = clock
      @monotonic = monotonic
      @page_loop = page_loop || Ingestion::PageLoop.new(
        executor: executor, writer: writer, configuration: configuration,
        rate_limit_policy: rate_limit_policy, clock: clock
      )
      @poll_state = poll_state || Ingestion::PollState.new(configuration: configuration, clock: clock)
    end

    # @param wait_seconds [Integer] how long to wait for the source lock. A parameter
    #   because the two callers have different contracts: the poller attempts once (§2A)
    #   and the one-shot retries for SOURCE_LOCK_WAIT_SECONDS (§9).
    # @param force [Boolean] §9's --force. It bypasses the configured cadence and omits the
    #   stored ETag, and nothing else. Both bypasses are visible below, a few lines apart;
    #   `force` is never handed to the page loop, the executor, the ledger, the rate-limit
    #   policy, or the poll-state writer, so everything else stays binding by construction
    #   rather than by promise. SourceLock.acquire wraps the call before force is read at
    #   all, so a forced run against a busy source still raises.
    # @return [Result]
    # @raise [Github::Errors::SourceBusy] the caller decides what a busy source means; §9
    #   makes it exit 0 for the one-shot and a deferred cycle for the poller.
    def call(event_source:, wait_seconds: SourceLock::POLLER_WAIT_SECONDS, force: false)
      requested_at = @monotonic.call

      SourceLock.acquire(event_source.id, wait_seconds: wait_seconds) do
        run(event_source.reload, force: force, lock_wait_ms: elapsed_ms(requested_at))
      end
    end

    private

    def run(event_source, force:, lock_wait_ms:)
      return out_of_service(event_source) if event_source.failed?

      now = @clock.call
      schedule = PollSchedule.for(event_source: event_source, now: now)
      return not_due(event_source, schedule, force: force) unless schedule.due?(now: now, force: force)

      poll(event_source, force: force, lock_wait_ms: lock_wait_ms)
    end

    # §10: "/events returns permanent 4xx → source failed/disabled". A source in that state
    # is not merely deferred, it is out of service, so this is checked before the schedule
    # rather than folded into it: `failed` is not a term of §9's formula, and it clears on
    # an operator's decision rather than at an instant.
    #
    # `force` is deliberately never consulted here. §9 enumerates what --force bypasses and
    # this is not on the list, and placing the check ahead of every use of `force` makes
    # that structural rather than a rule someone could later relax.
    def out_of_service(event_source)
      Rails.logger.warn(event: "ingestion.source_unavailable", event_source_id: event_source.id,
                        source_status: event_source.status, last_error: event_source.last_error)

      Result.new(run_id: nil, status: "deferred", deferral_reason: "source_failed")
    end

    def poll(event_source, force:, lock_wait_ms:)
      started_at = @monotonic.call
      recorder = Ingestion::RunRecorder.new(event_source: event_source, clock: @clock)
      recorder.start!

      Rails.logger.info(event: "ingestion.run_started", run_id: recorder.run_id,
                        event_source_id: event_source.id, source_type: event_source.source_type,
                        github_mode: @configuration.mode, forced: force, lock_wait_ms: lock_wait_ms)

      outcome = @page_loop.run(EventSources::Base.for(event_source), run_id: recorder.run_id,
                               etag: force ? nil : event_source.etag)
      finish(recorder, event_source, outcome, started_at: started_at)
    rescue Ingestion::PageLoop::WalkInterrupted => error
      # A crash that happened *after* a page came back. The request is spent either way, so
      # this records an attempted, failed poll — the cadence advances and the source backs
      # off, instead of the next invocation being immediately due and spending another
      # request into the same crash.
      finish(recorder, event_source, error.outcome, started_at: started_at) if recorder&.run
      raise error.cause
    rescue StandardError => error
      # Nothing was fetched, so nothing was attempted: the run row is closed and the
      # source's schedule is left exactly as the last real attempt left it.
      #
      # Finalize before re-raising either way, so no row is ever abandoned in `running` by
      # an error this class could see. A SIGKILL still leaves one, and that is the intended
      # crash signal.
      if recorder&.run
        finish(recorder, event_source, Ingestion::PageLoop::Outcome.failure(error), started_at: started_at)
      end
      raise
    end

    # No run row, no request, no reservation, and no writes — the source's state stays
    # exactly what the last real attempt left. The deferral names the *binding* component
    # rather than merely reporting that something deferred, so an operator is told which of
    # §9's five constraints to look at.
    def not_due(event_source, schedule, force:)
      next_poll_at = schedule.effective_poll_time(force: force)
      reason = schedule.binding_component(force: force)

      Rails.logger.info(event: "ingestion.not_due", event_source_id: event_source.id,
                        forced: force, deferral_reason: reason,
                        next_poll_at: next_poll_at&.utc&.iso8601, **schedule.to_log(force: force))

      Result.new(run_id: nil, status: "deferred", deferral_reason: reason&.to_s,
                 next_poll_at: next_poll_at)
    end

    def finish(recorder, event_source, outcome, started_at:)
      # Poll state first: next_poll_at has to reflect both this run's own cadence and any
      # block the rate-limit policy wrote while the pages were being walked, and the run's
      # completion line reports it.
      next_poll_at = @poll_state.record!(event_source: event_source, outcome: outcome)
      run = recorder.finish!(status: outcome.status, tally: outcome.tally, last_error: outcome.last_error)

      Rails.logger.public_send(
        outcome.failed? ? :error : :info,
        event: "ingestion.run_completed", run_id: run.run_id, event_source_id: run.event_source_id,
        duration_ms: elapsed_ms(started_at), next_poll_at: next_poll_at&.utc&.iso8601,
        consecutive_failures: event_source.consecutive_failures, **outcome.to_log
      )

      Result.new(run_id: run.run_id, status: outcome.status, tally: outcome.tally,
                 classification: outcome.classification, last_error: outcome.last_error,
                 deferral_reason: outcome.deferral_reason, next_poll_at: next_poll_at)
    end

    def elapsed_ms(from)
      ((@monotonic.call - from) * 1000).round(1)
    end
  end
end
