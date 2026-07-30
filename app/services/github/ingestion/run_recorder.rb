module Github
  module Ingestion
    # The ingestion_runs row's lifecycle (IMPLEMENTATION_PLAN.md §7, §11).
    #
    # A separate object because the run row is not the runner's subject matter, and because
    # run_id has to exist *before* the row does: §11 requires it on the correlated log
    # lines, the first of those lines is emitted as the run starts, and this codebase has
    # no tagged logging or log-context helper — so the value must be a plain argument the
    # runner already holds.
    #
    # That is why run_id is generated in Ruby and passed on insert. gen_random_uuid() stays
    # as the column default and remains the safety net for any hand-written insert (which
    # is what PR 3's model spec asserts); reading it back instead would mean an extra SELECT
    # and, worse, a run_started line with no correlation id on it.
    class RunRecorder
      # Long enough to identify the failure, short enough that the column is not a place
      # backtraces accumulate. §11 wants error class and message, not a stack.
      MAX_ERROR_LENGTH = 1000

      def initialize(event_source:, run_id: SecureRandom.uuid, clock: -> { Time.current })
        @event_source = event_source
        @run_id = run_id
        @clock = clock
      end

      attr_reader :event_source, :run_id, :run

      def start!
        @run = IngestionRun.create!(
          event_source: event_source, run_id: run_id,
          status: IngestionRun.statuses.fetch(:running), started_at: @clock.call
        )
      end

      # Counters are written once, here, from the in-memory tally.
      #
      # Not incrementally, and not inside the per-envelope transaction: §7 calls this row a
      # record of "one polling cycle" and §8 puts the durable record elsewhere ("an event is
      # accepted only after its push_events row is committed"). Updating it per envelope
      # would put a hot row and a held row lock inside the write path in exchange for
      # diagnostics that push_events.created_at already provides — and a running row with a
      # NULL completed_at is a more honest crash signal than counters that could disagree
      # with the events which actually committed.
      def finish!(status:, tally: Tally.empty, last_error: nil)
        raise ArgumentError, "no run has been started" if run.nil?

        run.update!(
          status: status, completed_at: @clock.call,
          last_error: last_error&.to_s&.truncate(MAX_ERROR_LENGTH),
          **tally.persistable_attributes
        )
        run
      end
    end
  end
end
