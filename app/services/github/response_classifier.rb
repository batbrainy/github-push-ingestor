module Github
  # "Basic response classification" (IMPLEMENTATION_PLAN.md §13, PR 4). A pure
  # function over a status and its headers: no I/O, no persistence, no scheduling.
  #
  # The line this class does not cross: it names what happened, it never acts on it.
  # Setting global_blocked_until, deriving class blocking, computing effective_poll_time,
  # applying Retry-After, and persisting ETags belong to Github::RateLimitPolicy,
  # Github::PollSchedule and Github::Ingestion::PollState. Marking an entity
  # permanent_failure is PR 7. What each of them branches on is produced here.
  module ResponseClassifier
    CLASSIFICATIONS = %i[
      ok not_modified redirect rate_limited secondary_limited
      not_found client_error server_error
    ].freeze

    # §10 distinguishes "403 or 429 with exhausted quota" from a secondary rate limit,
    # and the discriminator is the remaining count, not the status.
    LIMIT_STATUSES = [ 403, 429 ].freeze
    REDIRECT_STATUSES = [ 301, 302, 303, 307, 308 ].freeze
    # §10: an actor or repository URL returning 404/410 is an entity outcome. The
    # event source stays enabled — one deleted repository must never disable /events.
    GONE_STATUSES = [ 404, 410 ].freeze

    module_function

    def classify(status:, headers: {})
      headers = (headers || {}).transform_keys { |name| name.to_s.downcase }

      return :ok if status.between?(200, 299)
      return :not_modified if status == 304
      return redirect_classification(headers) if REDIRECT_STATUSES.include?(status)
      return limit_classification(headers) if LIMIT_STATUSES.include?(status)
      return :not_found if GONE_STATUSES.include?(status)
      return :client_error if status.between?(400, 499)
      return :server_error if status >= 500

      :client_error
    end

    # Only :server_error is retryable here. §10 lists exactly "5xx or network timeout"
    # as the retry case; every retry re-reserves scarce quota, so nothing else earns
    # one. Network-level failures are exceptions, not statuses, and Github::RetryPolicy
    # decides those.
    def retryable?(classification)
      classification == :server_error
    end

    def successful?(classification)
      classification == :ok || classification == :not_modified
    end

    def redirect_classification(headers)
      # A redirect with nowhere to go is a broken response, not a hop. Treating it as
      # a redirect would loop the executor against a nil target.
      headers["location"].present? ? :redirect : :client_error
    end

    def limit_classification(headers)
      remaining = headers["x-ratelimit-remaining"]

      # Primary exhaustion: do not retry, defer to the reset (§10). Otherwise it is a
      # secondary limit, which is IP-scoped and therefore blocks globally — including
      # enrichment, which has no source row to defer.
      remaining.to_s.strip == "0" ? :rate_limited : :secondary_limited
    end

    private_class_method :redirect_classification, :limit_classification
  end
end
