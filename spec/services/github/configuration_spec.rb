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
        actor_refresh_ttl_seconds: 86_400,
        repository_refresh_ttl_seconds: 86_400,
        # §11's coverage window, pinned at 86400 by §10. It arrives with the rich /status
        # rather than earlier because until Github::Enrichment::Coverage existed nothing
        # read it, and §16 forbids a knob with no consumer.
        enrichment_coverage_window_seconds: 86_400,
        # Appendix F's staged-enrichment block: the search lane's per-minute budget, the
        # core detail-fallback cap, and the cycle/retry/lease timings around them.
        core_detail_fallback_allowance: 4,
        search_request_ceiling: 10,
        search_safety_reserve: 2,
        search_batch_size: 10,
        search_pacing_seconds: 6,
        search_worker_concurrency: 1,
        enrichment_cycle_budget_seconds: 55,
        actor_enrichment_weight: 1,
        repository_enrichment_weight: 1,
        detail_fallback_max_attempts: 3,
        enrichment_lease_seconds: 600,
        enrichment_retry_base_seconds: 60,
        enrichment_retry_max_seconds: 3_600,
        enrichment_metrics_window_seconds: 3_600,
        catch_up_min_sample_seconds: 900,
        refresh_active_within_seconds: 604_800
      )
    end

    # The one knob here that changes what the system *reports* rather than what it *does*.
    # Stated as its own example because the distinction is the reason it is safe for two
    # processes to disagree about it, which is not true of any of its neighbours.
    it "reports through the coverage window without scheduling, reserving or deferring on it" do
      expect(configuration(ENRICHMENT_COVERAGE_WINDOW_SECONDS: "60"))
        .to have_attributes(enrichment_coverage_window_seconds: 60,
                            poll_interval_seconds: 300)
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

    it "accepts zero where zero is meaningful: no reserve, no retries, no redirects, no fallback" do
      config = configuration(RATE_LIMIT_RESERVE: "0", MAX_HTTP_RETRIES: "0", MAX_REDIRECTS: "0",
                             CORE_DETAIL_FALLBACK_ALLOWANCE: "0", SEARCH_SAFETY_RESERVE: "0")

      expect { config.validate! }.not_to raise_error
    end

    # Zero pacing is the offline fixture walkthrough's operating point: a one-shot runs
    # both lanes back to back with no wait between search requests.
    it "accepts zero pacing, which disables the wait rather than breaking it" do
      expect { configuration(SEARCH_PACING_SECONDS: "0").validate! }.not_to raise_error
    end

    it "rejects a negative value in every member of the non-negative group" do
      described_class::NON_NEGATIVE_INTEGERS.each_value do |variable|
        expect { configuration(variable.to_sym => "-1").validate! }
          .to raise_error(Github::Errors::ConfigurationError, /#{variable}/),
              "expected #{variable}=-1 to be rejected"
      end
    end
  end

  # Appendix F's structural rules between the staged-enrichment knobs: each one relates
  # two numbers, so the group validates after the sign checks and names the variable an
  # operator must move.
  describe "validation of the staged-enrichment knobs (Appendix F)" do
    it "rejects a search reserve that swallows the whole ceiling" do
      expect { configuration(SEARCH_SAFETY_RESERVE: "10").validate! }
        .to raise_error(Github::Errors::ConfigurationError, /SEARCH_SAFETY_RESERVE/)
    end

    it "accepts a reserve one below the ceiling, which leaves one spendable request" do
      expect { configuration(SEARCH_SAFETY_RESERVE: "9").validate! }.not_to raise_error
    end

    # GitHub caps repeated qualifiers well below the per_page maximum; ten is the batch
    # size the live probes behind Appendix F verified.
    it "accepts a batch size of ten and rejects eleven" do
      expect { configuration(SEARCH_BATCH_SIZE: "10").validate! }.not_to raise_error
      expect { configuration(SEARCH_BATCH_SIZE: "11").validate! }
        .to raise_error(Github::Errors::ConfigurationError, /SEARCH_BATCH_SIZE/)
    end

    # The global request gate serialises outbound calls, so a second search worker could
    # only queue behind the first while holding claims whose leases are burning down.
    it "requires exactly one search worker while the request gate serialises outbound calls" do
      expect { configuration(SEARCH_WORKER_CONCURRENCY: "2").validate! }
        .to raise_error(Github::Errors::ConfigurationError, /SEARCH_WORKER_CONCURRENCY/)
    end

    it "rejects a retry base above the retry ceiling, and accepts them equal" do
      expect { configuration(ENRICHMENT_RETRY_BASE_SECONDS: "3601").validate! }
        .to raise_error(Github::Errors::ConfigurationError, /ENRICHMENT_RETRY_BASE_SECONDS/)
      expect { configuration(ENRICHMENT_RETRY_BASE_SECONDS: "3600").validate! }.not_to raise_error
    end

    # The cycle runs inside a 60-second dispatch tick, so a budget at or past the tick
    # would let one cycle overlap the next dispatch decision.
    it "rejects a cycle budget at or above the sixty-second dispatch tick" do
      expect { configuration(ENRICHMENT_CYCLE_BUDGET_SECONDS: "60").validate! }
        .to raise_error(Github::Errors::ConfigurationError, /ENRICHMENT_CYCLE_BUDGET_SECONDS/)
      expect { configuration(ENRICHMENT_CYCLE_BUDGET_SECONDS: "59").validate! }.not_to raise_error
    end

    # A pacing wait the cycle budget cannot contain would defer every batch after the
    # first, forever: no cycle could ever wait out its own pacing.
    it "rejects a pacing interval the cycle budget cannot wait out" do
      expect { configuration(SEARCH_PACING_SECONDS: "55").validate! }
        .to raise_error(Github::Errors::ConfigurationError, /SEARCH_PACING_SECONDS/)
      expect { configuration(SEARCH_PACING_SECONDS: "54").validate! }.not_to raise_error
    end

    # The lease must outlive the worst-case single fetch — (MAX_HTTP_RETRIES + 1) x
    # (MAX_REDIRECTS + 1) attempts, each waiting out the gate and both HTTP timeouts —
    # or a slow-but-alive worker loses its claimed rows to a stale-lease reclaim
    # mid-request. 585 at the pinned defaults, and the boundary is strict.
    it "rejects a lease that the worst-case fetch could outlive, at the exact boundary" do
      expect { configuration(ENRICHMENT_LEASE_SECONDS: "585").validate! }
        .to raise_error(Github::Errors::ConfigurationError, /ENRICHMENT_LEASE_SECONDS/)
      expect { configuration(ENRICHMENT_LEASE_SECONDS: "586").validate! }.not_to raise_error
    end

    it "derives that worst case from the gate wait, the timeouts, the retries and the redirects" do
      expect(configuration.worst_case_fetch_seconds).to eq(585)
      expect(configuration(MAX_HTTP_RETRIES: "0", MAX_REDIRECTS: "0").worst_case_fetch_seconds).to eq(65)
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

  describe "startup validation of the allowance split (plan §10, Appendix F)" do
    it "accepts the pinned defaults, which commit twelve poll and four fallback attempts" do
      expect(configuration.validate!.allowances)
        .to have_attributes(poll_allowance: 12, enrichment_allowance: 4)
    end

    # Polling every 60 seconds is 60 attempts an hour — the entire unauthenticated
    # limit — which is exactly the V1 defect Appendix A item 2 records.
    it "rejects a cadence that would spend the whole hourly limit on polling" do
      expect { configuration(POLL_INTERVAL_SECONDS: "60").validate! }
        .to raise_error(Github::Errors::ConfigurationError, /exceed the core limit/)
    end

    # The message names CORE_DETAIL_FALLBACK_ALLOWANCE among the levers: the allowance
    # is a configured commitment now, so lowering it is a legitimate way out.
    it "names the offending numbers so an operator can fix it without reading the code" do
      expect { configuration(POLL_INTERVAL_SECONDS: "60").validate! }
        .to raise_error(/poll_allowance \(60\).*CORE_DETAIL_FALLBACK_ALLOWANCE \(4\).*RATE_LIMIT_RESERVE \(8\)/m)
    end

    # Appendix F's predicate is <= : the three commitments may fill the limit exactly,
    # because each is a real, funded plan — and the first request past it is rejected.
    it "accepts the sum landing exactly on the limit, and rejects one attempt more" do
      expect { configuration(RATE_LIMIT_RESERVE: "44").validate! }.not_to raise_error
      expect { configuration(RATE_LIMIT_RESERVE: "45").validate! }
        .to raise_error(Github::Errors::ConfigurationError, /CORE_DETAIL_FALLBACK_ALLOWANCE/)
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

  describe "#allowances" do
    it "derives from the configured source count, which is what keeps boot database-free" do
      expect(configuration(ENABLED_LIVE_SOURCE_COUNT: "2").allowances.poll_allowance).to eq(24)
    end

    # Github::BudgetLedger passes the count Github::SourceAllocation observed in
    # event_sources, at window initialization and rollover only (ADR 0004).
    it "accepts a count observed at runtime in place of the configured one" do
      expect(configuration.allowances(live_source_count: 3).poll_allowance).to eq(36)
    end
  end

  # The over-commitment the allowance formula cannot see: it counts one attempt per page,
  # while §10 makes every retry and every redirect hop its own reservation.
  describe "#worst_case_reservations_per_poll" do
    it "multiplies the retry, redirect and page ceilings, which is what one poll can cost" do
      expect(configuration.worst_case_reservations_per_poll).to eq(9)
    end

    it "is one request when nothing is retried, followed or paginated" do
      expect(configuration(MAX_HTTP_RETRIES: "0", MAX_REDIRECTS: "0", MAX_PAGES_PER_POLL: "1")
        .worst_case_reservations_per_poll).to eq(1)
    end

    it "counts every page, because a poll may fetch more than one" do
      expect(configuration(MAX_HTTP_RETRIES: "0", MAX_REDIRECTS: "0", MAX_PAGES_PER_POLL: "3")
        .worst_case_reservations_per_poll).to eq(3)
    end

    # A warning at boot rather than a rejection: this is a worst case a healthy endpoint
    # never reaches, and §10 requires runtime conditions to degrade rather than crash-loop.
    # The pinned defaults sit under the allowance, so a clean checkout says nothing.
    it "stays inside the poll allowance at the pinned defaults" do
      expect(configuration.worst_case_reservations_per_poll)
        .to be <= configuration.allowances.poll_allowance
    end

    it "exceeds it once retries and redirects are raised together" do
      raised = configuration(MAX_HTTP_RETRIES: "5", MAX_REDIRECTS: "5")

      expect(raised.worst_case_reservations_per_poll).to eq(36)
      expect(raised.worst_case_reservations_per_poll).to be > raised.allowances.poll_allowance
    end

    # It is a report, not a rule: §7 already accepts that these are request-*attempt*
    # allowances, so an amplifying configuration must still boot. The lease is raised
    # alongside, because the same retries and redirects stretch the worst-case fetch to
    # 2340 seconds and the lease rule is a genuine rejection.
    it "is not a rejection, so an amplifying configuration still validates" do
      amplified = configuration(MAX_HTTP_RETRIES: "5", MAX_REDIRECTS: "5",
                                ENRICHMENT_LEASE_SECONDS: "2341")

      expect { amplified.validate! }.not_to raise_error
    end
  end

  describe "the boot-time contract" do
    it "validates the real environment, so a clean checkout boots" do
      expect { described_class.new.validate! }.not_to raise_error
    end

    # ADR 0004 fixes this property, and PR 9's runtime source count is placed in
    # Github::SourceAllocation rather than here precisely to preserve it: `bin/rails
    # db:prepare`, `rails runner` and CI's schema load all run validation before any table
    # exists.
    it "reads no database, so it is safe before the schema is loaded" do
      expect(ActiveRecord::Base.connection).not_to receive(:exec_query)

      described_class.new.validate!.allowances
    end
  end
end
