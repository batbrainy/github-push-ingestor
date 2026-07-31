module Github
  # The parsed form of IMPLEMENTATION_PLAN.md §10's "headers to process". Purely a
  # parser: it reads, it never decides. Github::BudgetLedger reconciles against it in
  # PR 4, and Github::RateLimitPolicy makes the scheduling decisions from the same
  # values.
  #
  # Tolerant by design — an absent or unparseable header becomes nil rather than
  # raising. A rate-limit header this application cannot read must never be the reason
  # a successful response is discarded.
  class RateLimitSnapshot < Data.define(
    :resource, :limit, :remaining, :used, :reset_at,
    :poll_interval_seconds, :retry_after_seconds, :etag, :observed_at
  )
    class << self
      # Header names are matched lowercase; both transports downcase them on the way
      # out, and HTTP header names are case-insensitive regardless.
      def from_headers(headers, observed_at:)
        headers = (headers || {}).transform_keys { |name| name.to_s.downcase }

        new(
          resource: presence(headers["x-ratelimit-resource"]),
          limit: integer(headers["x-ratelimit-limit"]),
          remaining: integer(headers["x-ratelimit-remaining"]),
          used: integer(headers["x-ratelimit-used"]),
          reset_at: epoch(headers["x-ratelimit-reset"]),
          poll_interval_seconds: integer(headers["x-poll-interval"]),
          # Both RFC 9110 forms, normalized to a delta. GitHub documents delta-seconds and
          # is the only server this application talks to, but Retry-After is one of §10's
          # "headers to process" and an unread HTTP-date silently collapses a
          # server-supplied "wait 45 minutes" into the 60-second fallback — obeying an
          # instruction far shorter than the one that was given is the response most likely
          # to provoke further throttling.
          retry_after_seconds: retry_after(headers["retry-after"], observed_at: observed_at),
          etag: presence(headers["etag"]),
          observed_at: observed_at
        )
      end

      private

      def presence(value)
        value.nil? || value.to_s.strip.empty? ? nil : value.to_s.strip
      end

      def integer(value)
        Integer(presence(value), 10)
      rescue ArgumentError, TypeError
        nil
      end

      def epoch(value)
        seconds = integer(value)
        seconds && Time.zone.at(seconds)
      end

      # Delta-seconds first, since that is what GitHub sends and what the majority of
      # responses carry. The date form is resolved against observed_at rather than
      # Time.current so the snapshot stays a pure function of its inputs — the same headers
      # and the same observed_at always yield the same delta, which is what lets a spec
      # assert an instant without freezing the clock.
      #
      # A date already in the past yields a non-positive delta. That is deliberately not
      # normalized to nil here: this class reads and never decides, and
      # Github::RateLimitPolicy#fallback_instant already treats non-positive exactly as it
      # treats absent.
      def retry_after(value, observed_at:)
        integer(value) || http_date_delta(value, observed_at: observed_at)
      end

      def http_date_delta(value, observed_at:)
        text = presence(value)
        return nil if text.nil? || observed_at.nil?

        (Time.httpdate(text) - observed_at).round
      rescue ArgumentError
        nil
      end
    end

    # Whether there is enough here to reconcile the ledger's window at all. A 500 from
    # a proxy, or a transport failure with no response, carries none of it.
    def quantitative?
      !limit.nil? && !remaining.nil? && !reset_at.nil?
    end

    def exhausted?
      remaining == 0
    end

    def to_log
      { rate_limit_resource: resource, rate_limit_limit: limit, rate_limit_remaining: remaining,
        rate_limit_used: used, rate_limit_reset_at: reset_at&.iso8601 }.compact
    end
  end
end
