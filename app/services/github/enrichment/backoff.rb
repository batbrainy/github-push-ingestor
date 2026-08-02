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
    #     40/hour allowance: long enough for a blip to clear without monopolising the
    #     durable backlog.
    #   * MAX_SECONDS is one rate-limit window. A repeatedly failing entity yields to
    #     other due backlog entries for at most an hour before it becomes eligible again.
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
      # Issue #45 makes the retry ladder configurable; these remain as the documented
      # defaults ENRICHMENT_RETRY_BASE_SECONDS / ENRICHMENT_RETRY_MAX_SECONDS start from.
      BASE_SECONDS = 60
      MAX_SECONDS = 3600
      JITTER_FRACTION = 0.25

      # @param random [Random] injected so a spec asserts the schedule without sleeping.
      def initialize(random: Random.new, base_seconds: nil, max_seconds: nil,
                     configuration: nil)
        configuration ||= Github.configuration if base_seconds.nil? || max_seconds.nil?
        @base_seconds = base_seconds || configuration.enrichment_retry_base_seconds
        @max_seconds = max_seconds || configuration.enrichment_retry_max_seconds
        @random = random
      end

      attr_reader :base_seconds, :max_seconds

      # @param attempts [Integer] the count *including* the attempt being scheduled for,
      #   so the first failure waits base_seconds rather than half of it.
      # @return [Float] seconds
      def delay_for(attempts)
        exponent = [ attempts.to_i, 1 ].max - 1
        base = [ base_seconds * (2**exponent), max_seconds ].min

        # Capped after jitter, so max_seconds is an honest bound rather than a bound plus
        # up to 25%.
        [ base + (@random.rand * base * JITTER_FRACTION), max_seconds.to_f ].min
      end

      # @return [Time]
      def retry_at(attempts, now:)
        now + delay_for(attempts)
      end
    end
  end
end
