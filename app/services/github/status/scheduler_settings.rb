module Github
  module Status
    # Issue #45: every staged-enrichment scheduler knob, published. A pure projection of
    # the validated configuration — zero reads, always fully populated, so an operator
    # can see the numbers the ledgers and workers are actually enforcing without a shell.
    class SchedulerSettings < Data.define(:configuration)
      def self.from(configuration = Github.configuration)
        new(configuration: configuration)
      end

      def payload
        {
          search: {
            request_ceiling: configuration.search_request_ceiling,
            safety_reserve: configuration.search_safety_reserve,
            batch_size: configuration.search_batch_size,
            pacing_seconds: configuration.search_pacing_seconds,
            worker_concurrency: configuration.search_worker_concurrency
          },
          fairness: {
            actor_weight: configuration.actor_enrichment_weight,
            repository_weight: configuration.repository_enrichment_weight,
            actor_enrichment_share: configuration.actor_enrichment_share.to_f
          },
          core: {
            detail_fallback_allowance: configuration.core_detail_fallback_allowance,
            rate_limit_reserve: configuration.rate_limit_reserve
          },
          retry: {
            base_seconds: configuration.enrichment_retry_base_seconds,
            max_seconds: configuration.enrichment_retry_max_seconds,
            detail_fallback_max_attempts: configuration.detail_fallback_max_attempts,
            lease_seconds: configuration.enrichment_lease_seconds,
            cycle_budget_seconds: configuration.enrichment_cycle_budget_seconds
          },
          refresh: {
            actor_ttl_seconds: configuration.actor_refresh_ttl_seconds,
            repository_ttl_seconds: configuration.repository_refresh_ttl_seconds,
            active_within_seconds: configuration.refresh_active_within_seconds
          },
          metrics: {
            window_seconds: configuration.enrichment_metrics_window_seconds,
            catch_up_min_sample_seconds: configuration.catch_up_min_sample_seconds
          }
        }
      end
    end
  end
end
