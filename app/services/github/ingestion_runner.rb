module Github
  # One polling operation, end to end (IMPLEMENTATION_PLAN.md §5, §8 steps 1–9).
  #
  # §5 names this component and says what it owns: "IngestionRunner owns the source lock for
  # the duration of a polling operation. RequestExecutor does not own or acquire SourceLock
  # — its chain begins at the request gate and is identical for polling and enrichment."
  #
  # The sequence, and the two orderings that are load-bearing:
  #
  #   1. acquire the source lock                        §8 step 1
  #   2. open the ingestion_runs row — inside the lock, so Errors::SourceBusy provably
  #      cannot leave a stray running row behind
  #   3. fetch page one through Github.executor         §8 step 2, no transaction open
  #   4. branch on the classification *before* decoding §8 step 3
  #   5. hand the page to the writer                    §8 steps 4–9
  #   6. finalize the run row
  #
  # Step 4 is not a stylistic choice. Base#events calls JSON.parse(body.to_s), and a 304
  # carries no body — so decoding first would turn a perfectly healthy 304 into a
  # MalformedResponse and record a failed run. The 304 spec is what catches that inversion.
  #
  # Step 3 sits between two writes with no transaction open, because
  # Github::BudgetLedger#assert_committable! refuses a reservation inside one: "an outer
  # rollback would refund a request GitHub has already counted." That single guard is what
  # fixes this class's shape.
  #
  # What it deliberately does not do, all PR 6 (§13):
  #
  #   * No Link-header pagination. Page one only; MAX_PAGES_PER_POLL is an allowance-formula
  #     input until then.
  #   * No ETag. It never reads or writes event_sources.etag, so it never sends
  #     If-None-Match — the corpus still scripts a 304 as its second response, and a live
  #     304 can arrive from any cache, which is why the handling exists before the
  #     conditional request does.
  #   * No scheduling. No effective_poll_time, no cadence gate, no global_blocked_until, no
  #     Retry-After, and no writes to any event_sources column. ingestion_runs is PR 5's
  #     poll history and is strictly richer than a last_polled_at scalar.
  #
  # It also enqueues nothing. §8 step 10 is PR 8, and §8 already says why no list of created
  # ids is needed: "the committed entity state is the durable record of pending work
  # (outbox-style recovery)" — and the enrichment_candidates partial index for exactly that
  # predicate already exists.
  class IngestionRunner
    # Classifications where the request reached GitHub and GitHub declined to serve it.
    # Recorded as deferred rather than failed: §10 treats a rate limit as something to retry
    # later, and nothing is wrong with the request. Persisting the *until* — global_blocked_until,
    # retry_not_before_at — is PR 6's.
    DEFERRING_CLASSIFICATIONS = %i[ rate_limited secondary_limited ].freeze

    MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

    # One return type for every outcome, the same philosophy RequestExecutor#call applies to
    # requests: a caller branches once instead of rescuing four classes and eventually
    # missing one.
    class Result < Data.define(:run_id, :status, :tally, :classification, :last_error, :deferral_reason)
      def completed? = status == "completed"
      def not_modified? = status == "not_modified"
      def deferred? = status == "deferred"
      def failed? = status == "failed"

      def to_log
        { run_status: status, classification: classification, deferral_reason: deferral_reason,
          error_message: last_error }.compact.merge(tally.to_log)
      end
    end

    def initialize(executor: Github.executor, writer: Ingestion::PageWriter.new,
                   configuration: Github.configuration, clock: -> { Time.current },
                   monotonic: MONOTONIC)
      @executor = executor
      @writer = writer
      @configuration = configuration
      @clock = clock
      @monotonic = monotonic
    end

    # @param wait_seconds [Integer] how long to wait for the source lock. A parameter because
    #   the two callers have different contracts: the poller attempts once (§2A) and the
    #   one-shot retries for SOURCE_LOCK_WAIT_SECONDS (§9).
    # @param force [Boolean] §9's --force. Recorded on the run_started line and nothing else
    #   in PR 5: what it bypasses — the configured cadence and the stored ETag — is PR 6's,
    #   and neither exists to bypass yet.
    # @return [Result]
    # @raise [Github::Errors::SourceBusy] the caller decides what a busy source means; §9
    #   makes it exit 0 for the one-shot and a deferred cycle for the poller.
    def call(event_source:, wait_seconds: SourceLock::POLLER_WAIT_SECONDS, force: false)
      requested_at = @monotonic.call

      SourceLock.acquire(event_source.id, wait_seconds: wait_seconds) do
        run(event_source, force: force, lock_wait_ms: elapsed_ms(requested_at))
      end
    end

    private

    def run(event_source, force:, lock_wait_ms:)
      started_at = @monotonic.call
      recorder = Ingestion::RunRecorder.new(event_source: event_source, clock: @clock)
      recorder.start!

      Rails.logger.info(event: "ingestion.run_started", run_id: recorder.run_id,
                        event_source_id: event_source.id, source_type: event_source.source_type,
                        github_mode: @configuration.mode, forced: force, lock_wait_ms: lock_wait_ms)

      result = ingest(event_source, recorder)
      finish(recorder, result, started_at: started_at)
    rescue StandardError => error
      # Finalize before re-raising, so no row is ever abandoned in running by an error this
      # class could see. A SIGKILL still leaves one, and that is the intended crash signal.
      finish(recorder, failure(error), started_at: started_at) if recorder&.run
      raise
    end

    def ingest(event_source, recorder)
      source = EventSources::Base.for(event_source)
      fetched = @executor.call(source.first_page_request(context: { run_id: recorder.run_id }))

      Rails.logger.debug(event: "ingestion.page_fetched", run_id: recorder.run_id, page: 1,
                         http_status: fetched.status, classification: fetched.classification,
                         attempt: fetched.attempt, duration_ms: fetched.duration_ms)

      # Order matters: 304 and the deferrals carry no usable body, so they are answered before
      # anything tries to decode one.
      return outcome("not_modified", fetched) if fetched.not_modified?
      if fetched.deferred? || DEFERRING_CLASSIFICATIONS.include?(fetched.classification)
        return deferral(fetched, recorder.run_id)
      end
      return outcome("failed", fetched, last_error: describe(fetched)) unless fetched.ok?

      process(source, fetched, recorder)
    end

    def process(source, fetched, recorder)
      envelopes = source.events(fetched)
      tally = @writer.write(envelopes, run_id: recorder.run_id,
                            tally: Ingestion::Tally.empty.record_page(events_received: envelopes.size))

      outcome("completed", fetched, tally: tally)
    rescue Errors::MalformedResponse => error
      # §7's taxonomy row 5: an unusable response body is an ingestion failure, not an
      # individual quarantined event. Nothing about it identifies an event to quarantine.
      outcome("failed", fetched, last_error: "#{error.class.name}: #{error.message}")
    end

    # run_id is threaded in rather than left off: §11 makes it the correlation identifier for
    # the whole flow, and a deferral is exactly the line an operator greps for when a run
    # produced no events. Without it this would be the one ingestion line that cannot be
    # joined to the run it belongs to.
    def deferral(fetched, run_id)
      reason = fetched.deferred? ? deferral_reason(fetched) : fetched.classification.to_s

      Rails.logger.info(event: "ingestion.deferred", run_id: run_id, reason: reason,
                        classification: fetched.classification, http_status: fetched.status)

      outcome("deferred", fetched, deferral_reason: reason)
    end

    # Errors::BudgetExhausted carries which of §10's four denial conditions refused the
    # reservation, and that is the one actionable fact about a deferral.
    def deferral_reason(fetched)
      error = fetched.error

      error.is_a?(Errors::BudgetExhausted) ? error.reason.to_s : fetched.classification.to_s
    end

    def outcome(status, fetched, tally: Ingestion::Tally.empty, last_error: nil, deferral_reason: nil)
      Result.new(run_id: nil, status: status, tally: tally, classification: fetched&.classification,
                 last_error: last_error, deferral_reason: deferral_reason)
    end

    def failure(error)
      Result.new(run_id: nil, status: "failed", tally: Ingestion::Tally.empty, classification: nil,
                 last_error: "#{error.class.name}: #{error.message}", deferral_reason: nil)
    end

    def finish(recorder, result, started_at:)
      run = recorder.finish!(status: result.status, tally: result.tally, last_error: result.last_error)
      completed = result.with(run_id: run.run_id)

      Rails.logger.public_send(
        result.failed? ? :error : :info,
        event: "ingestion.run_completed", run_id: run.run_id, event_source_id: run.event_source_id,
        duration_ms: elapsed_ms(started_at), **completed.to_log
      )

      completed
    end

    # §10 keeps every HTTP status a response rather than an exception, so the reason a run
    # failed has to be assembled from the classification and, when there was no status at
    # all, from the transport error.
    def describe(fetched)
      return "#{fetched.error.class.name}: #{fetched.error.message}" if fetched.error

      "GitHub returned #{fetched.status} (#{fetched.classification})"
    end

    def elapsed_ms(from)
      ((@monotonic.call - from) * 1000).round(1)
    end
  end
end
