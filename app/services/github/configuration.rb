module Github
  # A typed, validated, immutable view of the process environment for everything that
  # touches a GitHub request (IMPLEMENTATION_PLAN.md §2A, §6, §10).
  #
  # Constructible from an explicit env hash, so a spec can describe an invalid
  # configuration without mutating the global ENV — which under `config.order = :random`
  # would leak into whichever example ran next.
  #
  # Two values are deliberately NOT environment variables:
  #
  #   * the allowed API host, which lives in Github::UrlPolicy. An env var there would
  #     turn the SSRF boundary into a deployment setting.
  #   * the REST API version, which §2A pins to the version this project's live-probe
  #     evidence was gathered under. Upgrading is a deliberate follow-up that
  #     re-verifies payload shape first, not a deploy-time toggle.
  class Configuration
    MODES = %w[ live fixture ].freeze

    # GitHub's documented unauthenticated primary limit, keyed to the outbound IP
    # (§10). An external fact rather than a policy choice, so it is a constant: it is
    # only the boot-time starting point, and the observed x-ratelimit-limit supersedes
    # it as soon as one response has been seen. The startup-validation rejection path
    # is exercised by lowering POLL_INTERVAL_SECONDS, not by moving this number.
    UNAUTHENTICATED_CORE_LIMIT = 60

    DEFAULTS = {
      "GITHUB_MODE" => "live",
      "GITHUB_FIXTURE_SCENARIO" => "default",
      "POLL_INTERVAL_SECONDS" => "300",
      "MAX_PAGES_PER_POLL" => "1",
      "ENABLED_LIVE_SOURCE_COUNT" => "1",
      "RATE_LIMIT_RESERVE" => "8",
      "HTTP_OPEN_TIMEOUT_SECONDS" => "5",
      "HTTP_READ_TIMEOUT_SECONDS" => "15",
      "MAX_HTTP_RETRIES" => "2",
      "MAX_REDIRECTS" => "2",
      "SOURCE_LOCK_WAIT_SECONDS" => "30",
      "ACTOR_ENRICHMENT_SHARE" => "0.50",
      "ACTOR_REFRESH_TTL_SECONDS" => "86400",
      "REPOSITORY_REFRESH_TTL_SECONDS" => "86400",
      "ENRICHMENT_COVERAGE_WINDOW_SECONDS" => "86400"
    }.freeze

    # A zero here is a broken configuration, not a conservative one: a zero interval
    # divides, and a zero page count or source count silently derives a poll allowance
    # of nothing.
    #
    # The two enrichment refresh timings join the group for the same reason. A zero
    # refresh TTL makes every enriched entity instantly stale, turning off the freshness
    # cache §13 lists as a PR 7 capability. "Never refresh" is a large number, not zero.
    #
    # The coverage window is reporting-only, and it fails the same way from the other end. It
    # is the sole denominator of §11's three percentages, so a zero window puts every
    # denominator at zero and Github::Enrichment::Coverage reports null for all three,
    # permanently — §11's headline metric disabled by a number rather than by a decision.
    # A negative value is worse than useless rather than merely useless: `now - (-N)` is a
    # floor in the *future*, which empties the window just as completely while reading
    # like a wider one.
    POSITIVE_INTEGERS = {
      poll_interval_seconds: "POLL_INTERVAL_SECONDS",
      max_pages_per_poll: "MAX_PAGES_PER_POLL",
      enabled_live_source_count: "ENABLED_LIVE_SOURCE_COUNT",
      http_open_timeout_seconds: "HTTP_OPEN_TIMEOUT_SECONDS",
      http_read_timeout_seconds: "HTTP_READ_TIMEOUT_SECONDS",
      source_lock_wait_seconds: "SOURCE_LOCK_WAIT_SECONDS",
      actor_refresh_ttl_seconds: "ACTOR_REFRESH_TTL_SECONDS",
      repository_refresh_ttl_seconds: "REPOSITORY_REFRESH_TTL_SECONDS",
      enrichment_coverage_window_seconds: "ENRICHMENT_COVERAGE_WINDOW_SECONDS"
    }.freeze

    # Zero is meaningful for all three: no reserve, no retries, no redirects.
    NON_NEGATIVE_INTEGERS = {
      rate_limit_reserve: "RATE_LIMIT_RESERVE",
      max_http_retries: "MAX_HTTP_RETRIES",
      max_redirects: "MAX_REDIRECTS"
    }.freeze

    # §10's fairness share. A named group of one rather than a one-off line, because the
    # group's *name* states its validation rule and a spec iterates it to prove every
    # member is rejected at its boundary — the shape the two integer groups already have.
    FRACTIONS = {
      actor_enrichment_share: "ACTOR_ENRICHMENT_SHARE"
    }.freeze

    # enrichment_coverage_window_seconds is the odd one out and worth naming as such: every
    # other knob here changes what the system *does*, and this one changes only what
    # Github::Enrichment::Coverage *reports*. Nothing schedules, reserves, or defers on it.
    attr_reader :mode, :fixture_scenario, :poll_interval_seconds, :max_pages_per_poll,
                :enabled_live_source_count, :rate_limit_reserve,
                :http_open_timeout_seconds, :http_read_timeout_seconds,
                :max_http_retries, :max_redirects, :source_lock_wait_seconds,
                :actor_enrichment_share, :actor_refresh_ttl_seconds, :repository_refresh_ttl_seconds,
                :enrichment_coverage_window_seconds

    def initialize(env = ENV)
      @mode = read(env, "GITHUB_MODE").downcase
      @fixture_scenario = read(env, "GITHUB_FIXTURE_SCENARIO")

      POSITIVE_INTEGERS.merge(NON_NEGATIVE_INTEGERS).each do |attribute, variable|
        instance_variable_set(:"@#{attribute}", integer(env, variable))
      end

      FRACTIONS.each do |attribute, variable|
        instance_variable_set(:"@#{attribute}", fraction(env, variable))
      end

      freeze
    end

    def live? = mode == "live"
    def fixture? = mode == "fixture"

    # One corpus directory holding one manifest; fixture_scenario selects a scenario
    # *inside* it rather than a directory of its own, so scenarios can inherit from
    # each other and share one set of body files.
    def fixture_root
      Rails.root.join("fixtures", "github")
    end

    # The limit to plan against: the last authoritative observation when there is one,
    # otherwise GitHub's documented unauthenticated limit. Callers pass
    # github_api_budget.limit, which is NULL until the first window is bootstrapped.
    def effective_limit(observed_limit = nil)
      observed_limit || UNAUTHENTICATED_CORE_LIMIT
    end

    # @param live_source_count [Integer] §10's ENABLED_LIVE_SOURCE_COUNT. Defaults to the
    #   configured value, which is what keeps #validate! a pure function of the environment
    #   (ADR 0004); Github::BudgetLedger passes the count Github::SourceAllocation observes
    #   in event_sources.
    def allowances(limit: UNAUTHENTICATED_CORE_LIMIT, live_source_count: enabled_live_source_count)
      Allowances.derive(configuration: self, limit: limit, live_source_count: live_source_count)
    end

    # How many reservations one *logical* poll can consume in the worst case, which is not
    # the one the allowance formula counts. §10 makes each retry and each redirect hop its
    # own reservation "through the same gate and ledger", and Github::RequestExecutor
    # restarts the redirect chain from the original request on a retryable failure — so a
    # single page can cost (retries + 1) x (redirects + 1) attempts, and a poll costs that
    # once per page it is allowed to fetch.
    #
    # At the pinned defaults: 3 x 3 x 1 = 9 of a 12-attempt poll allowance. It is reported
    # at boot rather than rejected — see the initializer for why.
    def worst_case_reservations_per_poll
      (max_http_retries + 1) * (max_redirects + 1) * max_pages_per_poll
    end

    # §10's per-class refresh TTLs, keyed by request class so a caller holding an
    # Enrichment::EntityType asks one question instead of branching.
    # @param request_class [Symbol] :actor or :repository
    def refresh_ttl_seconds(request_class)
      case request_class
      when :actor then actor_refresh_ttl_seconds
      when :repository then repository_refresh_ttl_seconds
      else raise ArgumentError, "no refresh TTL for request class #{request_class.inspect}"
      end
    end

    # Runs at boot (config/initializers/github.rb) and raises, so a misconfigured
    # budget stops the container instead of polling into an over-commitment. It
    # touches no database, no network, and no schema — pure arithmetic over the
    # environment — so `bin/rails db:prepare`, `rails runner`, and CI's schema load
    # are all safe to run before anything is migrated.
    def validate!
      raise Errors::ConfigurationError,
            "GITHUB_MODE must be one of #{MODES.join(", ")}, got #{mode.inspect}" unless MODES.include?(mode)

      POSITIVE_INTEGERS.each do |attribute, variable|
        value = public_send(attribute)
        raise Errors::ConfigurationError, "#{variable} must be greater than 0, got #{value}" unless value.positive?
      end

      NON_NEGATIVE_INTEGERS.each do |attribute, variable|
        value = public_send(attribute)
        raise Errors::ConfigurationError, "#{variable} must not be negative, got #{value}" if value.negative?
      end

      validate_fractions!
      validate_allowances!
      self
    end

    private

    # The closed interval, not an open one. Both ends are legal operating points:
    # Allowances.split floors, so an allowance of 1 already yields an actor guarantee of
    # zero from the pinned 0.50 share, and #clamped can yield 0/0 — so a zero guarantee
    # has to work correctly whatever validation permits. It is not a starve either,
    # because §10 gates borrowing on the *other* class having no currently eligible
    # candidate rather than on its counters: share 0.0 means "repository first, actors
    # during the quiet periods".
    #
    # What has no meaning is the complement. A negative share gives a negative actor
    # guarantee and therefore a repository guarantee *above* the class allowance, and a
    # share above one is the mirror image. Those are the over-commitments this rejects.
    def validate_fractions!
      FRACTIONS.each do |attribute, variable|
        value = public_send(attribute)
        next if (0..1).cover?(value)

        raise Errors::ConfigurationError,
              "#{variable} must be between 0 and 1 inclusive, got #{value.to_f}"
      end
    end

    def validate_allowances!
      derived = allowances
      return if derived.feasible?

      raise Errors::ConfigurationError, <<~MESSAGE.squish
        the polling requirement leaves no capacity for enrichment:
        poll_allowance (#{derived.poll_allowance}) + RATE_LIMIT_RESERVE (#{derived.reserve})
        reaches the #{derived.limit}/hour limit, leaving #{derived.enrichment_allowance}
        enrichment attempts. Raise POLL_INTERVAL_SECONDS, or lower MAX_PAGES_PER_POLL,
        ENABLED_LIVE_SOURCE_COUNT, or RATE_LIMIT_RESERVE.
      MESSAGE
    end

    def read(env, variable)
      value = env[variable]
      value.nil? || value.to_s.strip.empty? ? DEFAULTS.fetch(variable) : value.to_s.strip
    end

    # Integer() rather than #to_i, which turns "abc" into 0 and would let a typo
    # silently become the most permissive possible value.
    def integer(env, variable)
      Integer(read(env, variable), 10)
    rescue ArgumentError, TypeError
      raise Errors::ConfigurationError,
            "#{variable} must be an integer, got #{read(env, variable).inspect}"
    end

    # Rational() rather than Float(), for a reason stronger than the one Integer() is
    # used for above. The value is multiplied by an integer allowance and floored, and
    # IEEE-754 loses that by one at inputs an operator can reach: (100 * 0.29).floor is
    # 28 in Ruby, not the 29 the decimal says. Rational parses the digits the operator
    # typed, so floor(allowance x share) is the number on the page. It still compares
    # equal to a Float — Rational("0.50") == 0.5 — so specs and #to_f logging read
    # naturally.
    #
    # It is also strict where #to_f is not: "abc".to_f is 0.0, a perfectly legal share
    # that would silently starve actor enrichment for the life of the deployment.
    # ZeroDivisionError is rescued because Rational(String) also accepts the "1/2" form.
    def fraction(env, variable)
      Rational(read(env, variable))
    rescue ArgumentError, TypeError, ZeroDivisionError
      raise Errors::ConfigurationError,
            "#{variable} must be a decimal fraction, got #{read(env, variable).inspect}"
    end
  end
end
