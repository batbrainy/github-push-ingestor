# Every error this application raises for a GitHub request lives here, in one file
# under one namespace, because Zeitwerk maps app/services/github/errors.rb to
# Github::Errors and nothing else.
#
# The dividing line that matters: an HTTP status — any status, including 304, 403,
# and 500 — is a response, never an exception. Exceptions are reserved for the cases
# where no status was obtained at all, or where the request was refused before it was
# ever attempted (IMPLEMENTATION_PLAN.md §10).
module Github
  module Errors
    Error = Class.new(StandardError)

    # A configuration the process must not run with: an unknown mode, a non-positive
    # interval, or an allowance split that leaves no room for Story 3 enrichment.
    # Raised at boot, deliberately, so a misconfigured budget stops the container
    # instead of silently polling into an over-commitment (§10).
    ConfigurationError = Class.new(Error)

    # The SSRF boundary refused a URL (§10). Carries every reason the URL failed, not
    # just the first, so a log line names the whole problem. PR 7 maps this to an
    # entity's permanent_failure; PR 4 only reports it.
    class UrlPolicyViolation < Error
      attr_reader :url, :violations

      def initialize(url, violations)
        @url = url.to_s
        @violations = violations.freeze
        super("refused #{@url.inspect}: #{@violations.join(", ")}")
      end
    end

    # Bounded redirect following (§10). The hop count is exhausted, so the chain stops
    # rather than following one more validated target.
    RedirectLimitExceeded = Class.new(Error)

    # No request was attempted, so nothing was spent and nothing needs unwinding.
    class BudgetExhausted < Error
      attr_reader :request_class, :reason

      def initialize(request_class, reason)
        @request_class = request_class
        @reason = reason
        super("budget ledger refused a #{request_class} reservation: #{reason}")
      end
    end

    # The global request gate was not acquired within its wait. Also nothing spent —
    # this is a deferral, not a failure, and must not burn a source's failure count.
    GateUnavailable = Class.new(Error)

    # A source lock was unavailable. The poller exits; the one-shot prints its state
    # summary and exits 0 (§9). Not a failure either.
    SourceBusy = Class.new(Error)

    # The lock-order invariant (§2A, §5, CLAUDE.md) was violated, or a lock was
    # re-entered. Both are programming errors that would otherwise present as a
    # multi-container hang with nothing in the logs.
    LockOrderViolation = Class.new(Error)
    ReentrantLock = Class.new(Error)

    # The advisory lock was acquired on one PostgreSQL session and released from
    # another — the pool substituted the connection, or Active Record silently
    # reconnected. The lock is orphaned; failing loudly beats letting a second poller
    # believe it owns the source.
    LockSessionChanged = Class.new(Error)

    # No HTTP status was obtained.
    TransportError = Class.new(Error)
    ConnectionFailed = Class.new(TransportError)
    # Not `Timeout`: that name collides with the stdlib module inside this namespace.
    RequestTimeout = Class.new(TransportError)
    TlsError = Class.new(TransportError)

    # Fixture mode fails closed (§6, §12). A URL the corpus does not define is an
    # authoring bug, and it is never laundered into a retryable transport failure or
    # answered by a live request.
    FixtureMiss = Class.new(TransportError)

    # The corpus itself is unusable — missing, unparsable, or naming a body file that
    # does not exist. Distinct from a miss: the miss is about one URL, this is about
    # the corpus.
    FixtureCorpusError = Class.new(Error)
  end
end
