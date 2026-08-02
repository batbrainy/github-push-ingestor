module Github
  module Ingestion
    # Persists §9's "Polling state": the ETag, the scheduling components, last successful
    # poll time, and the consecutive-failure count. Budget state is global
    # (github_api_budget) and is never written here.
    #
    # One UPDATE, issued inside the source lock after the page walk has returned. Not
    # inside a transaction that spans a fetch, and not under `with_lock` — that would hold
    # a row lock on event_sources across HTTP, and BudgetLedger refuses a reservation
    # inside an open application transaction anyway.
    #
    # The rule the whole write matrix turns on: **the scheduling components move only when
    # a poll attempt actually happened.** §10 is explicit that a budget denial and a held
    # gate mean the request never happened, so letting either advance the cadence would
    # convert contention into lost captures, and letting either count as a failure would
    # burn a healthy source's backoff.
    #
    # consecutive_failures is a read-modify-write, and that is safe here for one reason
    # only: this runs inside SourceLock, the single place in the system where an
    # event_sources row has exactly one writer.
    class PollState
      def initialize(configuration: Github.configuration, backoff: PollBackoff.new,
                     clock: -> { Time.current })
        @configuration = configuration
        @backoff = backoff
        @clock = clock
      end

      # @param outcome [Github::Ingestion::PageLoop::Outcome]
      # @param run_id [String, nil] §11's correlation identifier, carried purely so the two
      #   failure lines below can be joined to the run that produced them. Optional because
      #   this class writes source state whether or not a run row exists, and a nil is
      #   compacted out rather than logged as null.
      # @return [Time, nil] the next_poll_at it wrote, which the runner puts on its Result
      #   so the one-shot can name §9's "Ingestion deferred until T" for any reason.
      def record!(event_source:, outcome:, now: @clock.call, run_id: nil)
        attributes = outcome.attempted? ? attempted(event_source, outcome, now: now) : {}
        attributes[:next_poll_at] = projected(event_source, attributes, now: now)

        event_source.update!(attributes)
        log_failure(event_source, outcome, attributes, run_id: run_id, now: now)
        attributes[:next_poll_at]
      end

      private

      # cadence_due_at is a fixed delay from the *end* of the run, not from its start.
      #
      # The argument is arithmetic rather than taste: the allowance formula grants
      # ceil(3600 / POLL_INTERVAL_SECONDS) attempts an hour — twelve at the defaults,
      # which is exactly a fixed-rate schedule with zero headroom. A drift-compensating
      # scheduler that fires early to make up for a slow run is therefore *guaranteed* to
      # ask for a thirteenth attempt the ledger will refuse. A forty-second run pushing the
      # next poll out to T+340 is the correct behaviour: POLL_INTERVAL_SECONDS is a floor
      # on the gap between polls, not a wall-clock timetable.
      def attempted(event_source, outcome, now:)
        attributes = { last_polled_at: now, cadence_due_at: now + @configuration.poll_interval_seconds }

        # X-Poll-Interval is a delta, and GitHub sends it on limit and error responses too,
        # so it is read from whatever came back. It self-expires and therefore needs no
        # clearing rule.
        floor = outcome.snapshot&.poll_interval_seconds.to_i
        attributes[:poll_floor_until] = now + floor if floor.positive?

        attributes[:etag] = outcome.etag if outcome.etag.present?

        attributes.merge(health(event_source, outcome, now: now))
      end

      def health(event_source, outcome, now:)
        return success(now: now) if outcome.successful?
        return failure(event_source, outcome, now: now) if outcome.failed?

        # A rate-limited or secondary-limited response: GitHub answered, so the attempt is
        # spent and the cadence moves, but nothing is wrong with the source. §10 says a
        # limit is not a failure, so consecutive_failures and last_error stay untouched.
        secondary_retry(outcome)
      end

      # retry_not_before_at and last_error are cleared, not merely left alone. Without the
      # clearing rule, one stale hour-long backoff keeps deferring a source that has been
      # healthy for its last three polls — the component becomes permanent rather than a
      # constraint.
      #
      # `status` is deliberately *not* written back to "idle". A success can only reach a
      # source that was schedulable, since IngestionRunner refuses to poll a failed one at
      # all — so writing it would be dead code that quietly returned a source to service
      # the moment the gate was bypassed. §10's failed state clears on an operator's
      # decision, and this is the only place that could have made it clear on its own.
      def success(now:)
        { last_success_at: now, consecutive_failures: 0, retry_not_before_at: nil, last_error: nil }
      end

      def failure(event_source, outcome, now:)
        attributes = { last_error: outcome.last_error }

        # §10: "/events returns permanent 4xx → source failed". Terminal on first
        # occurrence and operator-recoverable only, so there is nothing to back off from
        # and no counter worth raising — the source is out of service until someone looks.
        # `enabled` is left alone: that column means an operator turned this off, and two
        # representations of "off" is the drift trap.
        return attributes.merge(status: "failed") if outcome.source_failing

        failures = event_source.consecutive_failures + 1

        attributes.merge(consecutive_failures: failures,
                         retry_not_before_at: @backoff.retry_at(failures, now: now))
      end

      # §10: "also update the request-specific source or entity retry state". Not redundant
      # with the global block: ROLL_WINDOW_SQL clears that at the window boundary, while
      # this component survives it, so a secondary limit that outlives a rollover still
      # defers the source that provoked it.
      def secondary_retry(outcome)
        retry_at = outcome.decision&.source_retry_at

        retry_at.nil? ? {} : { retry_not_before_at: retry_at }
      end

      # next_poll_at is a cache of the answer, written from the values this run is about to
      # commit plus a ledger row that already carries any block RateLimitPolicy just wrote.
      # Nothing reads it back to make a decision — §9's five components are read
      # individually every time — because a cached instant goes stale the moment a block
      # clears, and consulting it would re-introduce the single collapsed timestamp §9
      # exists to avoid.
      def projected(event_source, attributes, now:)
        projection = event_source.dup
        projection.assign_attributes(attributes)

        PollSchedule.for(event_source: projection, now: now).effective_poll_time
      end

      # Logged from the attributes that were actually written, and only after the UPDATE
      # committed them: a line claiming a source is out of service before the row says so is
      # the one kind of log an operator cannot act on. Reading the written attributes rather
      # than re-deriving outcome.source_failing also means a future second path to `failed`
      # is reported without anyone remembering to extend this.
      #
      # This class logs rather than Github::IngestionRunner doing it on its behalf, for
      # three reasons. The enrichment runners are this class's entity-side mirror and
      # already log their own anomalies, so a state writer announcing its own
      # transitions is the established shape here. The runner would have to re-derive the
      # predicate, and two readers of one rule is drift waiting to happen. And only this
      # class knows the delay — backoff_seconds is retry_not_before_at minus its own `now`.
      #
      # ingestion.source_failed is §10's "/events returns permanent 4xx → source failed", and
      # it was the largest failure-logging gap in the system: the transition is terminal and
      # operator-recoverable only — nothing in this application writes `failed` back to
      # `idle` — so it is the single poll outcome that will not resolve itself, and the only
      # evidence of it was a status column nobody was told to read. Its entity-side twin,
      # permanent_failure, already reaches the INFO stream as enrichment.failed's
      # entity_status; this is the source-side line that was missing.
      #
      # It shares its token with IngestionRunner#out_of_service's deferral_reason, so one
      # grep for source_failed returns the transition *and* every poll subsequently refused.
      #
      # ingestion.source_backoff is the counted-failure half. ingestion.run_completed already
      # reports consecutive_failures and next_poll_at, but next_poll_at is the *maximum* of
      # §9's five independent components, so it cannot say whether the source is deferred by
      # its own backoff, by the server's poll floor, or by a global block. Naming the
      # component and the delay is what makes the retry actionable — the same reason
      # ingestion.not_due reports binding_component instead of only an instant.
      #
      # Nothing is logged for a run that was never attempted: attributes is empty, nothing
      # was written, and the runner's own ERROR-level run_completed reports it.
      def log_failure(event_source, outcome, attributes, run_id:, now:)
        return unless outcome.failed?

        if attributes[:status] == "failed"
          Rails.logger.error({ event: "ingestion.source_failed", run_id: run_id,
                               event_source_id: event_source.id, source_status: "failed",
                               classification: outcome.classification,
                               error_message: outcome.last_error }.compact)
        elsif attributes[:retry_not_before_at]
          retry_at = attributes[:retry_not_before_at]

          Rails.logger.warn({ event: "ingestion.source_backoff", run_id: run_id,
                              event_source_id: event_source.id,
                              classification: outcome.classification,
                              consecutive_failures: attributes[:consecutive_failures],
                              backoff_seconds: (retry_at - now).round(1),
                              retry_not_before_at: retry_at.utc.iso8601,
                              error_message: outcome.last_error }.compact)
        end
      end
    end
  end
end
