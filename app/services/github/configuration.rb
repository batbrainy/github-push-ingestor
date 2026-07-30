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
      "SOURCE_LOCK_WAIT_SECONDS" => "30"
    }.freeze

    # A zero here is a broken configuration, not a conservative one: a zero interval
    # divides, and a zero page count or source count silently derives a poll allowance
    # of nothing.
    POSITIVE_INTEGERS = {
      poll_interval_seconds: "POLL_INTERVAL_SECONDS",
      max_pages_per_poll: "MAX_PAGES_PER_POLL",
      enabled_live_source_count: "ENABLED_LIVE_SOURCE_COUNT",
      http_open_timeout_seconds: "HTTP_OPEN_TIMEOUT_SECONDS",
      http_read_timeout_seconds: "HTTP_READ_TIMEOUT_SECONDS",
      source_lock_wait_seconds: "SOURCE_LOCK_WAIT_SECONDS"
    }.freeze

    # Zero is meaningful for all three: no reserve, no retries, no redirects.
    NON_NEGATIVE_INTEGERS = {
      rate_limit_reserve: "RATE_LIMIT_RESERVE",
      max_http_retries: "MAX_HTTP_RETRIES",
      max_redirects: "MAX_REDIRECTS"
    }.freeze

    attr_reader :mode, :fixture_scenario, :poll_interval_seconds, :max_pages_per_poll,
                :enabled_live_source_count, :rate_limit_reserve,
                :http_open_timeout_seconds, :http_read_timeout_seconds,
                :max_http_retries, :max_redirects, :source_lock_wait_seconds

    def initialize(env = ENV)
      @mode = read(env, "GITHUB_MODE").downcase
      @fixture_scenario = read(env, "GITHUB_FIXTURE_SCENARIO")

      POSITIVE_INTEGERS.merge(NON_NEGATIVE_INTEGERS).each do |attribute, variable|
        instance_variable_set(:"@#{attribute}", integer(env, variable))
      end

      freeze
    end

    def live? = mode == "live"
    def fixture? = mode == "fixture"

    def fixture_root
      Rails.root.join("fixtures", "github", fixture_scenario)
    end

    # The limit to plan against: the last authoritative observation when there is one,
    # otherwise GitHub's documented unauthenticated limit. Callers pass
    # github_api_budget.limit, which is NULL until the first window is bootstrapped.
    def effective_limit(observed_limit = nil)
      observed_limit || UNAUTHENTICATED_CORE_LIMIT
    end

    def allowances(limit: UNAUTHENTICATED_CORE_LIMIT)
      Allowances.derive(configuration: self, limit: limit)
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

      validate_allowances!
      self
    end

    private

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
  end
end
