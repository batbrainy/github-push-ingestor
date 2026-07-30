require "rails_helper"

RSpec.describe Github::Configuration do
  # Constructed from an explicit hash rather than the process environment: mutating
  # ENV under `config.order = :random` would leak into whichever example ran next.
  def configuration(**overrides)
    described_class.new(overrides.transform_keys(&:to_s))
  end

  describe "the pinned operational defaults (plan §2A, §10)" do
    it "matches the plan's pinned values with an empty environment" do
      config = configuration

      expect(config).to have_attributes(
        mode: "live",
        poll_interval_seconds: 300,
        max_pages_per_poll: 1,
        enabled_live_source_count: 1,
        rate_limit_reserve: 8,
        http_open_timeout_seconds: 5,
        http_read_timeout_seconds: 15,
        max_http_retries: 2,
        max_redirects: 2,
        source_lock_wait_seconds: 30,
        # §10's enrichment block. Rational("0.50") == 0.5, so the literal reads naturally
        # while the arithmetic stays exact.
        actor_enrichment_share: 0.5,
        enrichment_eligibility_window_seconds: 3600,
        actor_refresh_ttl_seconds: 86_400,
        repository_refresh_ttl_seconds: 86_400
      )
    end

    # §10 prints ENRICHMENT_COVERAGE_WINDOW_SECONDS in the same block as the three above,
    # but it is an input to §11's coverage percentages, which §13 assigns to PR 10. §16
    # forbids speculative infrastructure, so it is absent until something reads it.
    it "carries no coverage window, which is PR 10's input and has no consumer yet" do
      expect(described_class::DEFAULTS.keys).not_to include("ENRICHMENT_COVERAGE_WINDOW_SECONDS")
    end

    it "reads an override from the environment it was given" do
      expect(configuration(MAX_PAGES_PER_POLL: "3").max_pages_per_poll).to eq(3)
    end

    # Docker Compose passes an empty string for an unset ${VAR:-} interpolation, and
    # an empty string is not an override — treating it as one would set the value to 0.
    it "treats a blank value as unset rather than as an override" do
      expect(configuration(POLL_INTERVAL_SECONDS: "  ").poll_interval_seconds).to eq(300)
    end

    it "is frozen, so no caller can retune the budget after startup validation ran" do
      expect(configuration).to be_frozen
    end
  end

  describe "the mode" do
    it "defaults to live, because live ingestion is the default runtime behavior" do
      expect(configuration).to be_live
    end

    it "accepts fixture mode case-insensitively" do
      expect(configuration(GITHUB_MODE: "FIXTURE")).to be_fixture
    end

    it "rejects an undocumented mode instead of falling back to one of them" do
      expect { configuration(GITHUB_MODE: "offline").validate! }
        .to raise_error(Github::Errors::ConfigurationError, /GITHUB_MODE/)
    end

    # One corpus, one manifest: the scenario names a section inside it rather than a
    # directory of its own, so scenarios can inherit and share body files.
    it "points at the single corpus directory whatever scenario is selected" do
      expect(configuration(GITHUB_FIXTURE_SCENARIO: "paginated").fixture_root.to_s)
        .to end_with("fixtures/github")
      expect(configuration(GITHUB_FIXTURE_SCENARIO: "paginated").fixture_scenario).to eq("paginated")
    end
  end

  describe "validation of the numeric knobs" do
    # #to_i would turn "abc" into 0, and a zero interval or page count is the most
    # permissive possible misconfiguration.
    it "rejects a non-integer rather than coercing it to zero" do
      expect { configuration(MAX_HTTP_RETRIES: "abc") }
        .to raise_error(Github::Errors::ConfigurationError, /MAX_HTTP_RETRIES/)
    end

    it "rejects a non-positive value where zero is meaningless" do
      described_class::POSITIVE_INTEGERS.each_value do |variable|
        expect { configuration(variable.to_sym => "0").validate! }
          .to raise_error(Github::Errors::ConfigurationError, /#{variable}/),
              "expected #{variable}=0 to be rejected"
      end
    end

    it "accepts zero where zero is meaningful: no reserve, no retries, no redirects" do
      config = configuration(RATE_LIMIT_RESERVE: "0", MAX_HTTP_RETRIES: "0", MAX_REDIRECTS: "0")

      expect { config.validate! }.not_to raise_error
    end

    it "rejects a negative retry or redirect count" do
      expect { configuration(MAX_REDIRECTS: "-1").validate! }
        .to raise_error(Github::Errors::ConfigurationError, /MAX_REDIRECTS/)
    end
  end

  describe "the enrichment fairness share (plan §10)" do
    # "abc".to_f is 0.0 — a perfectly legal share that would starve actor enrichment for
    # the life of the deployment without a single error anywhere.
    it "rejects a share that is not a number, rather than coercing it to the zero that starves actors" do
      expect { configuration(ACTOR_ENRICHMENT_SHARE: "abc") }
        .to raise_error(Github::Errors::ConfigurationError, /ACTOR_ENRICHMENT_SHARE/)
    end

    # A negative share gives a negative actor guarantee, and therefore a repository
    # guarantee *above* the class allowance — an over-commitment only the class guard
    # would catch.
    it "rejects a negative share, which would put the repository guarantee above the allowance" do
      expect { configuration(ACTOR_ENRICHMENT_SHARE: "-0.1").validate! }
        .to raise_error(Github::Errors::ConfigurationError, /ACTOR_ENRICHMENT_SHARE/)
    end

    it "rejects a share above one, which is the same over-commitment mirrored" do
      expect { configuration(ACTOR_ENRICHMENT_SHARE: "1.1").validate! }
        .to raise_error(Github::Errors::ConfigurationError, /ACTOR_ENRICHMENT_SHARE/)
    end

    # The interval is closed on purpose. A zero guarantee is reachable by arithmetic
    # anyway — an allowance of 1 floors to 0/1 at the pinned share — and §10 relieves it
    # through borrowing rather than through the split, so refusing the input while
    # permitting the derived state would only pretend it is impossible.
    it "accepts both ends of the closed interval, because borrowing relieves a zero guarantee" do
      %w[ 0.0 1.0 ].each do |share|
        expect { configuration(ACTOR_ENRICHMENT_SHARE: share).validate! }.not_to raise_error
      end
    end

    it "parses the share exactly, so a two-decimal fraction floors to the number on the page" do
      expect(configuration(ACTOR_ENRICHMENT_SHARE: "0.29").actor_enrichment_share).to eq(Rational(29, 100))
    end

    it "rejects a non-positive eligibility window, which would skip every candidate on sight" do
      expect { configuration(ENRICHMENT_ELIGIBILITY_WINDOW_SECONDS: "0").validate! }
        .to raise_error(Github::Errors::ConfigurationError, /ENRICHMENT_ELIGIBILITY_WINDOW_SECONDS/)
    end

    it "rejects a zero refresh TTL, which would turn the freshness cache off from a number alone" do
      expect { configuration(ACTOR_REFRESH_TTL_SECONDS: "0").validate! }
        .to raise_error(Github::Errors::ConfigurationError, /ACTOR_REFRESH_TTL_SECONDS/)
    end
  end

  describe "#refresh_ttl_seconds" do
    it "answers per request class, so a caller holding an entity type asks once" do
      config = configuration(ACTOR_REFRESH_TTL_SECONDS: "60", REPOSITORY_REFRESH_TTL_SECONDS: "120")

      expect(config.refresh_ttl_seconds(:actor)).to eq(60)
      expect(config.refresh_ttl_seconds(:repository)).to eq(120)
    end

    it "refuses a class that has no TTL rather than returning a silent default" do
      expect { configuration.refresh_ttl_seconds(:poll) }.to raise_error(ArgumentError, /poll/)
    end
  end

  describe "startup validation of the allowance split (plan §10)" do
    it "accepts the pinned defaults, which leave forty enrichment attempts an hour" do
      expect(configuration.validate!.allowances)
        .to have_attributes(poll_allowance: 12, enrichment_allowance: 40)
    end

    # Polling every 60 seconds is 60 attempts an hour — the entire unauthenticated
    # limit — which is exactly the V1 defect Appendix A item 2 records.
    it "rejects a cadence that would spend the whole hourly limit on polling" do
      expect { configuration(POLL_INTERVAL_SECONDS: "60").validate! }
        .to raise_error(Github::Errors::ConfigurationError, /no capacity for enrichment/)
    end

    it "names the offending numbers so an operator can fix it without reading the code" do
      expect { configuration(POLL_INTERVAL_SECONDS: "60").validate! }
        .to raise_error(/poll_allowance \(60\).*RATE_LIMIT_RESERVE \(8\)/m)
    end

    it "rejects the exact boundary, because a zero enrichment allowance fails Story 3" do
      expect { configuration(RATE_LIMIT_RESERVE: "48").validate! }
        .to raise_error(Github::Errors::ConfigurationError)
    end

    it "returns itself when valid, so the initializer can validate and assign in one line" do
      config = configuration

      expect(config.validate!).to equal(config)
    end
  end

  describe "#effective_limit" do
    it "plans against GitHub's documented unauthenticated limit before any header" do
      expect(configuration.effective_limit(nil)).to eq(60)
    end

    # §7: the ledger converges to GitHub's headers, which are authoritative. The
    # constant is only the starting point for the very first window.
    it "prefers an observed limit, because response headers are the source of truth" do
      expect(configuration.effective_limit(5_000)).to eq(5_000)
    end
  end

  describe "the boot-time contract" do
    it "validates the real environment, so a clean checkout boots" do
      expect { described_class.new.validate! }.not_to raise_error
    end
  end
end
