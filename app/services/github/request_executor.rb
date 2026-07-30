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
        return result unless @retry_policy.retry?(classification: result.classification, attempt: attempt)

        # The backoff happens with no lock held and no reservation outstanding: the
        # previous attempt has already been debited and its gate hold released.
        @sleeper.call(@retry_policy.backoff_seconds(attempt))
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
        @ledger.reserve!(request.request_class, now: @clock.call)

        # Authoritative, in-chain validation: its return value is what the transport
        # receives, so an unvalidated URL cannot physically reach a socket.
        response = @transport.get(validate(request), headers: request.headers)

        # Inside the hold, per §2A's "perform one request -> reconcile headers ->
        # release gate".
        @ledger.reconcile!(rate_limit_from(response), now: @clock.call)

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

    # Payload- and Link-supplied URLs go through the payload path, which always applies
    # the full live policy first and only then projects onto the fixture scheme — so
    # fixture mode is never a weaker boundary than live.
    def validate(request)
      UrlPolicy.validate_payload_url!(request.url, mode: @mode)
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

    # §11 pins the common fields; the JSON formatter merges a hash into the log root.
    # DEBUG because §11 puts per-request lines there and keeps INFO for run summaries.
    def log_result(result)
      Rails.logger.debug(result.to_log.merge(event: "github.request"))
      result
    end
  end
end
