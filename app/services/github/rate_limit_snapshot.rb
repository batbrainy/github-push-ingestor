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
          # Seconds only. GitHub documents a delta, and the HTTP-date form is left
          # unparsed on purpose: §10 already defines the fallback for a missing
          # Retry-After (at least a minute, with exponential backoff), so nil is a
          # handled outcome rather than a gap.
          retry_after_seconds: integer(headers["retry-after"]),
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
