module Github
  # Source-scoped backoff for event_sources.retry_not_before_at (§9, §10).
  #
  # Deliberately not Github::RetryPolicy#backoff_seconds, which is a different domain
  # wearing the same shape. That one is *in-request* retry: `attempt` counts tries inside
  # one fetch, is bounded by MAX_HTTP_RETRIES (2), starts at a 1-second base, and needs no
  # ceiling because it can never reach one. This counts *polls*, is unbounded in
  # principle, is measured against a 300-second cadence that would swallow a 1-second
  # delay whole, and must be capped so a source that has been dead for a day is still
  # retried hourly rather than deferred into next week.
  #
  # Jitter is additive only. Subtracting could schedule a retry sooner than the floor,
  # and the floor is the one property §10 states numerically ("≥ 1 minute").
  class PollBackoff
    # Never sooner than the X-Poll-Interval floor observed on the live feed. A source
    # that just failed has no business being retried faster than a healthy one.
    BASE_SECONDS = 60
    # One rate-limit window. Past this, waiting longer buys nothing: the budget has
    # refreshed and the next attempt costs one of a fresh sixty.
    MAX_SECONDS = 3600
    JITTER_FRACTION = 0.25

    # @param random [Random] injected so a spec asserts the schedule without sleeping and
    #   without a stubbed Kernel.
    def initialize(random: Random.new)
      @random = random
    end

    # @param consecutive_failures [Integer] the count *including* the failure being
    #   scheduled for, so the first failure waits BASE_SECONDS rather than half of it.
    # @return [Float] seconds
    def delay_for(consecutive_failures)
      exponent = [ consecutive_failures.to_i, 1 ].max - 1
      base = [ BASE_SECONDS * (2**exponent), MAX_SECONDS ].min

      # Capped after jitter, so MAX_SECONDS is an honest bound rather than a bound plus
      # up to 25%.
      [ base + (@random.rand * base * JITTER_FRACTION), MAX_SECONDS.to_f ].min
    end

    # @return [Time]
    def retry_at(consecutive_failures, now:)
      now + delay_for(consecutive_failures)
    end
  end
end
