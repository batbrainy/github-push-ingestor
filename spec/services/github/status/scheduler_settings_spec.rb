require "rails_helper"

RSpec.describe Github::Status::SchedulerSettings do
  describe "#payload" do
    # The block exists so an operator can read the numbers the ledgers and workers are
    # actually enforcing without a shell. Full-hash equality, so a knob added to the
    # configuration cannot be forgotten here silently and a dropped key cannot hide.
    it "publishes every staged-enrichment knob from the configuration it was given" do
      configuration = configuration_with(
        SEARCH_REQUEST_CEILING: "9", SEARCH_SAFETY_RESERVE: "3", SEARCH_BATCH_SIZE: "5",
        SEARCH_PACING_SECONDS: "4", ACTOR_ENRICHMENT_WEIGHT: "2",
        REPOSITORY_ENRICHMENT_WEIGHT: "3", ACTOR_ENRICHMENT_SHARE: "0.25",
        CORE_DETAIL_FALLBACK_ALLOWANCE: "6", RATE_LIMIT_RESERVE: "5",
        ENRICHMENT_RETRY_BASE_SECONDS: "30", ENRICHMENT_RETRY_MAX_SECONDS: "1800",
        DETAIL_FALLBACK_MAX_ATTEMPTS: "2", ENRICHMENT_LEASE_SECONDS: "700",
        ENRICHMENT_CYCLE_BUDGET_SECONDS: "50", ACTOR_REFRESH_TTL_SECONDS: "43200",
        REPOSITORY_REFRESH_TTL_SECONDS: "86400",
        REFRESH_ACTIVE_WITHIN_SECONDS: "302400",
        ENRICHMENT_METRICS_WINDOW_SECONDS: "1800", CATCH_UP_MIN_SAMPLE_SECONDS: "600"
      )

      expect(described_class.from(configuration).payload).to eq(
        search: {
          request_ceiling: 9, safety_reserve: 3, batch_size: 5,
          pacing_seconds: 4, worker_concurrency: 1
        },
        fairness: { actor_weight: 2, repository_weight: 3, actor_enrichment_share: 0.25 },
        core: { detail_fallback_allowance: 6, rate_limit_reserve: 5 },
        retry: {
          base_seconds: 30, max_seconds: 1800, detail_fallback_max_attempts: 2,
          lease_seconds: 700, cycle_budget_seconds: 50
        },
        refresh: {
          actor_ttl_seconds: 43_200, repository_ttl_seconds: 86_400,
          active_within_seconds: 302_400
        },
        metrics: { window_seconds: 1800, catch_up_min_sample_seconds: 600 }
      )
    end

    it "publishes the pinned defaults for an untouched environment" do
      expect(described_class.from(configuration_with).payload).to include(
        search: {
          request_ceiling: 10, safety_reserve: 2, batch_size: 10,
          pacing_seconds: 6, worker_concurrency: 1
        },
        core: { detail_fallback_allowance: 4, rate_limit_reserve: 8 },
        metrics: { window_seconds: 3600, catch_up_min_sample_seconds: 900 }
      )
    end

    # The configuration stores the share as a Rational so the guarantee floor is exact;
    # a JSON payload wants the plain decimal an operator typed, as a Float.
    it "renders the actor enrichment share as a Float" do
      share = described_class.from(configuration_with).payload
                             .dig(:fairness, :actor_enrichment_share)

      expect(share).to be_a(Float)
      expect(share).to eq(0.5)
    end

    # A pure projection of validated configuration: zero reads, zero writes, so the
    # scheduler block can never disagree with the environment the process booted with.
    it "touches the database not at all" do
      settings = described_class.from(configuration_with)

      expect(capture_sql { settings.payload }).to be_empty
    end
  end
end
