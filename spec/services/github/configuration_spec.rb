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
        source_lock_wait_seconds: 30
      )
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

    it "resolves the corpus directory from the selected scenario" do
      expect(configuration(GITHUB_FIXTURE_SCENARIO: "paginated").fixture_root.to_s)
        .to end_with("fixtures/github/paginated")
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
