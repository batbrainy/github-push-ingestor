module Github
  module Status
    # Everything IMPLEMENTATION_PLAN.md §11 (as amended by Appendix G) asks GET /status
    # to report, taken as one snapshot of persisted state.
    #
    # **It never initiates a GitHub request**, and it is structural rather than a promise,
    # exactly as Github::Ingestion::StateSummary states it: this class holds no executor, no
    # transport and no ledger, and its only collaborators are Active Record models and pure
    # value objects. Github::BudgetLedger and Github::SearchBudgetLedger are absent by
    # construction — their public methods write, and bootstrap! would create from a read
    # path the very row a reservation owns. Every ledger read here is find_by. The specs
    # pin it: a recording transport that must see nothing, unchanged singleton counts, and
    # a SQL subscriber that must see no write statement.
    #
    # ## Read inventory, and why each read happens once
    #
    # - github_api_budget and github_search_budget: one find_by each, handed down to every
    #   block that needs them — independent reads could straddle a committing reservation
    #   and publish blocks that contradict each other.
    # - one aggregate statement per entity table (Enrichment::BacklogMetrics), captured
    #   once and shared by the enrichment and throughput blocks so they cannot disagree.
    # - one grouped statement over enrichment_batches (Enrichment::BatchQuality).
    # - one statement for coverage (unchanged §11 percentages).
    # - zero reads: scheduler settings (pure configuration), both ledger projections.
    #
    # ## #payload, not #to_log
    #
    # A third rendering, deliberately named apart from the two that exist. #to_s is the
    # CLI's column-aligned block and #to_log is the INFO stream's projection — and both
    # #to_log implementations call .compact, dropping nil keys. A JSON client needs a fixed
    # key set: a field that appears and disappears makes every consumer handle two shapes.
    class Snapshot < Data.define(:captured_at, :sources, :ledger, :search_ledger,
                                 :scheduler, :enrichment, :batches, :throughput, :coverage)
      def self.capture(now: Time.current, configuration: Github.configuration)
        budget = GithubApiBudget.find_by(id: GithubApiBudget::SINGLETON_ID)
        search_budget = GithubSearchBudget.find_by(id: GithubSearchBudget::SINGLETON_ID)
        backlog = Enrichment::BacklogMetrics.capture(now: now, configuration: configuration)
        runs = latest_runs

        new(
          captured_at: now,
          sources: EventSource.order(:id).map do |event_source|
            SourceState.from(event_source, budget: budget,
                                           last_run: runs[event_source.id], now: now)
          end,
          ledger: LedgerState.from(budget, configuration: configuration),
          search_ledger: SearchLedgerState.from(search_budget, configuration: configuration,
                                                now: now),
          scheduler: SchedulerSettings.from(configuration),
          enrichment: Enrichment::Summary.capture(now: now, configuration: configuration,
                                                  budget: budget,
                                                  search_budget: search_budget,
                                                  backlog: backlog),
          batches: Enrichment::BatchQuality.capture(now: now, configuration: configuration),
          throughput: Enrichment::Throughput.from(backlog, now: now,
                                                  configuration: configuration),
          coverage: Enrichment::Coverage.capture(now: now, configuration: configuration)
        )
      end

      # Every source's latest *finished* run, whatever its outcome — §11 asks /status for the
      # "last run", and the field is named last_run rather than last_successful_run because
      # that is what it is.
      #
      # Deliberately not IngestionRun.latest_successful, which is §9's question and belongs
      # to Github::Ingestion::StateSummary's "Latest successful run" line. Filtering to
      # successes here would hide a fresh failed or deferred run behind an older 200 or 304,
      # so an operator opening /status to find out why nothing is moving would be shown a
      # healthy last_run for a source that had just failed or backed off — the one state
      # this endpoint exists to surface. The status is in the payload, so a failed run
      # reports itself rather than being inferred from its absence.
      #
      # completed_at IS NOT NULL stays: it excludes exactly the `running` status, a run
      # still in flight that has reached no outcome to report. It is also what the ORDER BY
      # sorts on, so a NULL would sort unpredictably against the rest.
      #
      # One statement for every source rather than one per source: DISTINCT ON collapses to
      # the first row of each event_source_id group, and the ORDER BY defines "first". id
      # DESC is the tie-break for two runs that finished in the same microsecond — without
      # it the winner is whichever the plan happened to emit.
      def self.latest_runs
        IngestionRun.where.not(completed_at: nil)
                    .select("DISTINCT ON (event_source_id) event_source_id, run_id, status, completed_at")
                    .order(:event_source_id, completed_at: :desc, id: :desc)
                    .index_by(&:event_source_id)
      end
      private_class_method :latest_runs

      # `null` throughout, never a sentinel string and never a missing key. §16's rule is
      # that an unknown must not read as a zero, and the way to honour that in JSON is not
      # to swap the type — a `remaining` that is sometimes an Integer and sometimes
      # "not yet initialized" forces every consumer to type-check. It is: a counted zero
      # prints 0, a number that does not exist prints null, and wherever null would carry
      # two meanings the disambiguating fact gets its own field — ledger.present,
      # search_ledger.present, due_now, claimable_now, catch_up.state.
      def payload
        { captured_at: Ingestion::Report.timestamp(captured_at),
          sources: sources.map(&:payload),
          ledger: ledger.payload,
          search_ledger: search_ledger.payload,
          scheduler: scheduler.payload,
          enrichment: enrichment_payload,
          batches: batches.payload,
          throughput: throughput.payload,
          coverage: coverage.payload }
      end

      private

      # Each entity class exposes the durable backlog separately from its raw status
      # counts, plus the staged-pipeline view: every stage with its count and oldest
      # FIFO instant, and the contract backlog — rows not yet at the useful-data
      # contract or a terminal outcome. A backlog row may be temporarily deferred by
      # retry backoff, so these numbers intentionally differ from claimable_now. Queue
      # depth is not published: jobs are bounded wake-up hints and entity rows are the
      # source of truth.
      def enrichment_payload
        { actors: entity_counts(enrichment.actor),
          repositories: entity_counts(enrichment.repository),
          claimable_now: enrichment.claimable_now,
          next_enrichment_at: Ingestion::Report.timestamp(enrichment.next_enrichment_at) }
      end

      # fetch(status, 0) because the aggregate drops a status with no rows. These zeros
      # are counted, not fabricated: the table was read and held nothing. Stage counts
      # arrive with their zeros already present.
      def entity_counts(entry)
        Enrichable::ENRICHMENT_STATUSES
          .index_with { |status| entry.status_counts.fetch(status, 0) }
          .symbolize_keys
          .merge(backlog_count: entry.backlog_count,
                 contract_backlog_count: entry.contract_backlog_count,
                 oldest_pending_at: Ingestion::Report.timestamp(entry.oldest_pending_at),
                 oldest_pending_age_seconds: entry.oldest_pending_age_seconds,
                 stages: stage_payload(entry))
      end

      def stage_payload(entry)
        Enrichable::ENRICHMENT_STAGES.index_with do |stage|
          oldest = entry.stage_oldest.fetch(stage, nil)
          { count: entry.stage_counts.fetch(stage, 0),
            oldest_created_at: Ingestion::Report.timestamp(oldest),
            oldest_age_seconds: Enrichment::BacklogMetrics.age_seconds(oldest, now: captured_at) }
        end.symbolize_keys
      end
    end
  end
end
