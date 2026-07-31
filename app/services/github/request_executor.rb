module Github
  # The single path every live GitHub request takes, identical for polling and
  # enrichment (CLAUDE.md, IMPLEMENTATION_PLAN.md §5, §10):
  #
  #   request gate -> budget ledger reservation -> URL policy -> transport
  #
  # The source lock sits *outside* this class. PR 5's IngestionRunner holds it around a
  # whole polling operation; enrichment requests belong to no event source and never
  # take one. This class is never handed an event_source_id, which is the structural
  # half of that separation (Appendix D item 1); Github::LockOrder is the enforced half.
  #
  # One gate hold = one HTTP attempt = one reservation. §2A puts "exactly one GitHub
  # request" inside the gate, and §10 requires every retry to be its own reservation
  # "through the same gate and ledger" — the same *mechanism*, not the same *hold*.
  # Holding a global serial lock across a backoff sleep would stall every other process
  # in the application for the duration of that sleep.
  #
  # #call never raises for a runtime outcome. A budget denial, a URL-policy violation, a
  # busy gate, exhausted retries and a transport failure all come back as a FetchResult,
  # so a caller has exactly one return type to branch on. The one exception is a fixture
  # corpus gap, which §6 requires to be raised.
  class RequestExecutor
    def initialize(transport: Github.transport,
                   ledger: BudgetLedger.new,
                   retry_policy: RetryPolicy.new,
                   mode: Github.configuration.mode,
                   max_redirects: Github.configuration.max_redirects,
                   request_gate_wait: RequestGate::WAIT_SECONDS,
                   sleeper: ->(seconds) { Kernel.sleep(seconds) },
                   clock: -> { Time.current })
      @transport = transport
      @ledger = ledger
      @retry_policy = retry_policy
      @mode = mode.to_sym
      @max_redirects = max_redirects
      @request_gate_wait = request_gate_wait
      @sleeper = sleeper
      @clock = clock
    end

    # @param request [Github::Request]
    # @return [Github::FetchResult]
    def call(request)
      attempt = 0

      loop do
        result = follow_redirects(request, attempt: attempt)
        unless @retry_policy.retry?(classification: result.classification, attempt: attempt)
          return exhausted(result)
        end

        # Computed once and both slept and logged, never recomputed: RetryPolicy jitters, so
        # asking twice would report a delay this process never took.
        backoff_seconds = @retry_policy.backoff_seconds(attempt)
        log_retry_scheduled(result, backoff_seconds: backoff_seconds)

        # The backoff happens with no lock held and no reservation outstanding: the
        # previous attempt has already been debited and its gate hold released.
        @sleeper.call(backoff_seconds)
        attempt += 1
      end
    end

    private

    # A retryable failure at hop n restarts from the original request rather than from
    # the last hop, so MAX_HTTP_RETRIES keeps its plain meaning: this logical fetch was
    # attempted N times.
    def follow_redirects(request, attempt:)
      current = request
      hop = 0

      loop do
        result = gated_attempt(current, attempt: attempt)
        return result unless result.classification == :redirect

        if hop >= @max_redirects
          return failure(current, Errors::RedirectLimitExceeded.new(
            "stopped after #{@max_redirects} redirects from #{request.url}"
          ), attempt: attempt)
        end

        current = current.redirected_to(result.location)
        hop += 1
      end
    end

    # Exactly one outbound request per gate hold (§2A).
    def gated_attempt(request, attempt:)
      # Validated before the gate as well as inside it. validate! is pure, and this
      # pre-check is what stops an SSRF-violating enrichment URL from *debiting budget*:
      # §7's "failures stay spent" is about outbound attempts, and a URL the policy
      # refuses is never sent.
      validate(request)

      RequestGate.hold(wait_seconds: @request_gate_wait) do
        # The borrow travels on the request so a redirect hop and a retry — both of
        # which reserve again — stay authorized under the same fairness decision the
        # caller made once (§10). This class does not interpret it and could not
        # compute it: it is a fact about the entity tables.
        @ledger.reserve!(request.request_class, now: @clock.call, borrow: request.borrow)

        # Authoritative, in-chain validation: its return value is what the transport
        # receives, so an unvalidated URL cannot physically reach a socket.
        response = @transport.get(validate(request), headers: request.headers)

        # Inside the hold, per §2A's "perform one request -> reconcile headers ->
        # release gate".
        # The class travels with the reconciliation so that a response proving the
        # rate-limit window has moved on can carry this request's debit into the window
        # GitHub actually counted it in.
        @ledger.reconcile!(rate_limit_from(response), request_class: request.request_class,
                           now: @clock.call)

        log_result(FetchResult.from_response(
          request: request, status: response.status, headers: response.headers,
          body: response.body, duration_ms: response.duration_ms, attempt: attempt
        ))
      end
    rescue Errors::BudgetExhausted => e
      log_result(failure(request, e, attempt: attempt, classification: :budget_denied))
    rescue Errors::GateUnavailable => e
      log_result(failure(request, e, attempt: attempt, classification: :gate_unavailable))
    rescue Errors::FixtureMiss
      # Deliberately not converted into a FetchResult. §6: "if a URL is not present in
      # the corpus, a fixture error is raised". A corpus gap is an authoring bug, not a
      # runtime outcome, and laundering it into a failed fetch would let a fixture-mode
      # demo report a plausible-looking failure instead of naming the missing entry.
      raise
    rescue Errors::UrlPolicyViolation, Errors::TransportError => e
      log_result(failure(request, e, attempt: attempt))
    end

    # A location GitHub supplied — a payload URL, a Link target, a Location header —
    # always clears the full *live* policy first and is only then projected onto the
    # fixture scheme, so fixture mode is never a weaker boundary than live and a
    # response body cannot forge a corpus address.
    #
    # A location this application constructed is validated against the current mode
    # directly, which is what lets the offline event source address the corpus with a
    # fixture:// URL that no payload could ever supply.
    def validate(request)
      if request.payload_supplied?
        UrlPolicy.validate_payload_url!(request.url, mode: @mode)
      else
        UrlPolicy.validate!(request.url, mode: @mode)
      end
    end

    def rate_limit_from(response)
      RateLimitSnapshot.from_headers(response.headers, observed_at: @clock.call)
    end

    def failure(request, error, attempt:, classification: nil)
      FetchResult.from_error(
        request: request, error: error, attempt: attempt,
        classification: classification || RetryPolicy.classification_for(error)
      )
    end

    # §11 names "retry scheduled" among the INFO events, and it is what makes §10's "retry
    # up to MAX_HTTP_RETRIES with exponential backoff and jitter" observable rather than
    # merely implemented. Without it a retried fetch is indistinguishable from a slow one,
    # and the extra reservations it spends out of sixty an hour are invisible.
    #
    # Every §11 common field arrives free through FetchResult#to_log: it merges
    # Request#to_log, whose context carries the run_id for a poll and the entity identifiers
    # for an enrichment, so correlation needs no argument here.
    #
    # next_attempt is spelled out rather than left to arithmetic on a zero-based attempt,
    # because the operator reading this line is being told what happens next.
    def log_retry_scheduled(result, backoff_seconds:)
      Rails.logger.info(
        event: "github.retry_scheduled", **result.to_log,
        next_attempt: result.attempt + 1, max_attempts: @retry_policy.max_attempts,
        backoff_seconds: backoff_seconds.round(1)
      )
    end

    # The loop stops for two different reasons and only one of them is news. A
    # classification that was never retryable is an ordinary terminal outcome the caller
    # already records; a retryable one that ran out of attempts is §10's "persist the
    # failure after attempts are exhausted", and until now the stream could not tell them
    # apart — "failed three times over seven seconds and gave up" was byte-identical to
    # "failed once, permanently".
    #
    # WARN rather than ERROR, for the reason #log_result gives: the durable verdict belongs
    # to the caller — a failed run, a retryable_failure entity — and this is the evidence
    # behind it. With MAX_HTTP_RETRIES=0 the line still fires, carrying max_attempts: 0,
    # which is the honest report that configuration rather than GitHub ended the attempt.
    def exhausted(result)
      return result unless RetryPolicy.retryable_classification?(result.classification)
      return result unless result.attempt >= @retry_policy.max_attempts

      Rails.logger.warn(event: "github.retry_exhausted", **result.to_log,
                        max_attempts: @retry_policy.max_attempts)
      result
    end

    # §11 pins the common fields; the JSON formatter merges a hash into the log root.
    #
    # The level is a function of the outcome, the way Github::IngestionRunner#finish and
    # Github::Enrichment::Dispatch already vary theirs. §11 puts per-request lines at DEBUG
    # and that is right for the ones that worked — but §11 also sizes the INFO stream so the
    # events Story 4 asks reviewers to see are *in* it, and §16 requires failures to carry
    # actionable context. config.log_level defaults to info, so before this a 500, a
    # timeout, a refused URL and a deleted entity produced no HTTP detail at all in a
    # running system: the classification, the status, the URL and the attempt number live
    # here and nowhere else.
    #
    # One event name rather than two, so the same request never appears twice and
    # `grep github.request` keeps meaning "every request".
    def log_result(result)
      payload = { event: "github.request", **result.to_log }

      result.failed? ? Rails.logger.warn(payload) : Rails.logger.debug(payload)
      result
    end
  end
end
