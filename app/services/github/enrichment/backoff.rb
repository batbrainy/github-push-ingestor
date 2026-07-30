module Github
  module Enrichment
    # Entity-scoped backoff for github_actors.next_retry_at and its repository twin
    # (§9, §10).
    #
    # The arithmetic is Github::PollBackoff's, and the duplication is deliberate rather
    # than an oversight. That class's own comment sets the test — "a different domain
    # wearing the same shape" — and applying it here separates them:
    #
    #   * PollBackoff::BASE_SECONDS is 60 because that is the X-Poll-Interval floor
    #     observed on the live feed. Entities have no X-Poll-Interval. Sixty is chosen
    #     here because it matches Github::RateLimitPolicy::MIN_BLOCK_SECONDS and sits well
    #     below the ~90-second mean interval between enrichment requests at the default
    #     40/hour allowance: long enough for a blip to clear, short enough that the
    #     backoff is never the reason an entity ages out.
    #   * MAX_SECONDS is one rate-limit window, which does transfer, and gains a second
    #     enrichment-specific justification: it equals the pinned
    #     ENRICHMENT_ELIGIBILITY_WINDOW_SECONDS, so a backoff can never outlast the window
    #     that would age the row into skipped_budget. The cap is never what strands a row.
    #   * The counting unit differs. PollBackoff counts polls of one source; this counts
    #     fetch attempts against one entity, since the last success.
    #
    # Reusing PollBackoff by injection was the rejected alternative: an operator tuning
    # the poll floor would silently change entity retry behaviour, which is exactly the
    # coupling PollBackoff was extracted from Github::RetryPolicy to avoid.
    #
    # Jitter is additive only, for PollBackoff's reason: subtracting could schedule a
    # retry sooner than the floor, and the floor is the one property §10 states
    # numerically.
    class Backoff
      BASE_SECONDS = 60
      MAX_SECONDS = 3600
      JITTER_FRACTION = 0.25

      # @param random [Random] injected so a spec asserts the schedule without sleeping.
      def initialize(random: Random.new)
        @random = random
      end

      # @param attempts [Integer] the count *including* the attempt being scheduled for,
      #   so the first failure waits BASE_SECONDS rather than half of it.
      # @return [Float] seconds
      def delay_for(attempts)
        exponent = [ attempts.to_i, 1 ].max - 1
        base = [ BASE_SECONDS * (2**exponent), MAX_SECONDS ].min

        # Capped after jitter, so MAX_SECONDS is an honest bound rather than a bound plus
        # up to 25%.
        [ base + (@random.rand * base * JITTER_FRACTION), MAX_SECONDS.to_f ].min
      end

      # @return [Time]
      def retry_at(attempts, now:)
        now + delay_for(attempts)
      end
    end
  end
end
