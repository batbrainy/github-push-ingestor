module Github
  module Enrichment
    # What bin/enrich prints to prove enrichment state, alongside the block bin/ingest
    # already prints (Github::Ingestion::StateSummary).
    #
    # A second object rather than more members on that one, because the two answer
    # different questions and §13 splits them across two PRs: StateSummary is §9's
    # proof-of-state for the *polling* command, and §11 assigns the coverage percentages to
    # PR 10's /status. What lands here is the part PR 7's own outcome would otherwise be
    # invisible without — the per-status counts and the per-class share usage §10 defines —
    # and deliberately not the percentages, which need ENRICHMENT_COVERAGE_WINDOW_SECONDS
    # and a join against push_events.
    #
    # **It never initiates a GitHub request**, structurally and for StateSummary's reason:
    # no executor, no transport, no ledger — three read statements over Active Record
    # models. Reading the ledger row with find_by rather than through
    # Github::BudgetLedger matters for the same reason PollSchedule gives: a read path must
    # not create the row.
    class Summary < Data.define(:actor_counts, :repository_counts, :actor_share_used,
                                :repository_share_used, :actor_guarantee,
                                :repository_guarantee, :enrichment_used,
                                :enrichment_allowance, :window_status, :next_enrichment_at)
      NO_LEDGER = "not yet initialized".freeze
      DUE_NOW = "due now".freeze

      # The three statuses an operator acts on. permanent_failure and retryable_failure are
      # rolled into the pending/complete/skipped triple's remainder rather than printed
      # separately: §11's line is "pending/skipped counts", and a five-column row would
      # bury the two numbers that describe the sampling rate.
      REPORTED_STATUSES = %w[ pending complete skipped_budget ].freeze

      class << self
        def capture(now: Time.current, configuration: Github.configuration,
                    selector: CandidateSelector.new(configuration: configuration))
          budget = GithubApiBudget.find_by(id: GithubApiBudget::SINGLETON_ID)
          guarantees = guarantees_for(budget, configuration)

          new(
            actor_counts: counts(GithubActor),
            repository_counts: counts(GithubRepository),
            actor_share_used: budget&.actor_share_used,
            repository_share_used: budget&.repository_share_used,
            actor_guarantee: guarantees[:actor], repository_guarantee: guarantees[:repository],
            enrichment_used: budget&.enrichment_used,
            enrichment_allowance: budget&.enrichment_allowance,
            window_status: budget&.window_status,
            next_enrichment_at: next_enrichment_at(budget, selector, now: now)
          )
        end

        private

        def counts(model)
          model.group(:enrichment_status).count
        end

        def guarantees_for(budget, configuration)
          return { actor: nil, repository: nil } if budget.nil?

          Allowances.split(budget.enrichment_allowance, configuration.actor_enrichment_share)
        end

        # §9's effective_enrichment_time, answered for the *pool* rather than for one row:
        # when nothing is currently claimable, the soonest instant at which something will
        # be. A pure computation over rows that were read anyway.
        def next_enrichment_at(budget, selector, now:)
          global = [ budget&.global_blocked_until, budget&.enrichment_class_blocked_until(now: now) ].compact.max
          return global if global&.>(now)

          EntityType.all.filter_map { |type| selector.earliest_retry_at(type, now: now) }.min
        end
      end

      def to_s
        [
          # Kept under Report::LABEL_WIDTH so both values land in the same column as every
          # other line in the report — a label that fills the width exactly gets no padding
          # at all and its value runs straight into the colon.
          Ingestion::Report.line("Actors pending/complete/skipped", status_line(actor_counts)),
          Ingestion::Report.line("Repos pending/complete/skipped", status_line(repository_counts)),
          Ingestion::Report.line("Actor requests used", share_line(actor_share_used, actor_guarantee)),
          Ingestion::Report.line("Repository requests used", share_line(repository_share_used, repository_guarantee)),
          Ingestion::Report.line("Enrichment requests used", share_line(enrichment_used, enrichment_allowance)),
          Ingestion::Report.line("Next enrichment due", next_enrichment)
        ].join("\n")
      end

      def to_log
        { actor_counts: actor_counts, repository_counts: repository_counts,
          actor_share_used: actor_share_used, repository_share_used: repository_share_used,
          actor_guarantee: actor_guarantee, repository_guarantee: repository_guarantee,
          enrichment_used: enrichment_used, enrichment_allowance: enrichment_allowance,
          window_status: window_status,
          next_enrichment_at: Ingestion::Report.timestamp(next_enrichment_at) }.compact
      end

      private

      def status_line(counts)
        REPORTED_STATUSES.map { |status| Ingestion::Report.count(counts.fetch(status, 0)) }.join(" / ")
      end

      # "of" rather than a slash, so this line cannot be misread as the status triple above
      # it. NO_LEDGER for the same reason StateSummary spells its unknowns out: a fabricated
      # zero on a fresh install is exactly the misleading guarantee §16 forbids.
      def share_line(used, allowance)
        return NO_LEDGER if used.nil?

        "#{Ingestion::Report.count(used)} of #{Ingestion::Report.count(allowance)}"
      end

      def next_enrichment
        return DUE_NOW if next_enrichment_at.nil?

        Ingestion::Report.timestamp(next_enrichment_at)
      end
    end
  end
end
