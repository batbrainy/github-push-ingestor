module Github
  # IMPLEMENTATION_PLAN.md §10: retry a 5xx or a network timeout up to MAX_HTTP_RETRIES,
  # with exponential backoff and jitter, then persist the failure. Do not crash-loop.
  #
  # Each retry attempt is a fresh reservation through the same gate and ledger, so an
  # attempt is not free — it costs one of sixty requests an hour. That is why the
  # retryable set is exactly the two cases §10 names and nothing more.
  class RetryPolicy
    # What a terminal failure means for the thing that was being fetched. PR 5 maps
    # :permanent on a poll to a failed source, and PR 7 maps :permanent on an entity to
    # enrichment_status = "permanent_failure" and :defer to next_retry_at. PR 4 decides
    # which of the three a failure is, and writes no entity or source state at all.
    DISPOSITIONS = %i[ retry defer permanent ].freeze

    # Nothing was spent and nothing was attempted: a busy gate, a busy source, or a
    # ledger that refused. Deferring is the correct response, and treating any of them
    # as a failure would burn consecutive_failures on a healthy source.
    DEFERRED_ERRORS = [
      Errors::BudgetExhausted, Errors::GateUnavailable,
      Errors::SourceBusy, Errors::LockSessionChanged
    ].freeze

    RETRYABLE_ERRORS = [ Errors::ConnectionFailed, Errors::RequestTimeout ].freeze

    RETRY_BASE_DELAY_SECONDS = 1.0
    RETRY_JITTER_FRACTION = 0.25

    def initialize(max_attempts: Github.configuration.max_http_retries, random: Random.new)
      @max_attempts = max_attempts
      @random = random
    end

    attr_reader :max_attempts

    # attempt is zero-based: attempt 0 is the first try, so MAX_HTTP_RETRIES of 2
    # allows attempts 1 and 2 and stops there.
    def retry?(classification:, attempt:)
      return false if attempt >= max_attempts

      self.class.retryable_classification?(classification)
    end

    # Full jitter on top of an exponential base. Jitter matters even with one process:
    # the worker and the one-shot can collide on the same failing endpoint, and
    # identical backoffs would keep them in lockstep. The Random is injected so the
    # schedule is asserted without sleeping.
    def backoff_seconds(attempt)
      base = RETRY_BASE_DELAY_SECONDS * (2**attempt)

      base + (@random.rand * base * RETRY_JITTER_FRACTION)
    end

    class << self
      # TLS failures are deliberately NOT retryable. §10 lists only 5xx and network
      # timeouts; a certificate problem will not clear within two attempts, it may be
      # an interception attempt, and each retry spends quota that polling needs.
      def disposition(error)
        return :defer if DEFERRED_ERRORS.any? { |klass| error.is_a?(klass) }
        return :retry if RETRYABLE_ERRORS.any? { |klass| error.is_a?(klass) }

        :permanent
      end

      # A transport failure that produced no status still has to arrive at the caller
      # as a classification, so the executor and the retry loop branch on one vocabulary.
      def classification_for(error)
        disposition(error) == :retry ? :transport_error : :permanent_error
      end

      # Whether this classification is retryable *at all*, with the attempt budget left out
      # of the question.
      #
      # #retry? folds the two together, which is exactly what a caller deciding whether to
      # loop again needs. A caller explaining why the loop *stopped* has to separate them:
      # "never retryable" and "out of attempts" are different facts, and only the second is
      # §10's "persist the failure after attempts are exhausted". Without the split, the
      # exhaustion line would fire on every permanent 404.
      #
      # Named for the classification rather than as a bare retryable? because
      # ResponseClassifier.retryable? answers a narrower question — only :server_error —
      # and two same-named predicates with different answers is the drift trap.
      def retryable_classification?(classification)
        ResponseClassifier.retryable?(classification) || classification == :transport_error
      end
    end
  end
end
