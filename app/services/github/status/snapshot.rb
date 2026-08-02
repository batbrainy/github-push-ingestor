module Github
  module Status
    # Everything IMPLEMENTATION_PLAN.md §11 asks GET /status to report, taken as one
    # snapshot of persisted state.
    #
    # **It never initiates a GitHub request**, and it is structural rather than a promise,
    # exactly as Github::Ingestion::StateSummary states it: this class holds no executor, no
    # transport and no ledger, and its only collaborators are Active Record models and pure
    # value objects. Github::BudgetLedger is absent by construction — all four of its public
    # methods write, and #bootstrap! would create from a read path the very row a
    # reservation owns. Every ledger read here is find_by. Four specs pin it: a recording
    # transport that must see nothing, an unchanged github_api_budget count, an unchanged
    # event_sources count, and a SQL subscriber that must see no write statement.
    #
    # ## Why one aggregate rather than StateSummary + Summary side by side
    #
    # Three parts of this response need github_api_budget: the poll schedule, §11's ledger
    # block, and the enrichment block. Composing the two existing summaries would read the
    # singleton three times, so a reservation committing mid-request could produce one body
    # whose poll block contradicts its ledger block. This reads the row **once** and passes
    # it down. StateSummary additionally runs an unbounded PushEvent.count that §11 does not
    # ask for here, collapses PollSchedule to a single instant behind a private method when
    # §11 wants the components, and exposes neither poll_used, poll_allowance nor reserve.
    #
    # ## #payload, not #to_log
    #
    # A third rendering, deliberately named apart from the two that exist. #to_s is the
    # CLI's column-aligned block and #to_log is the INFO stream's projection — and both
    # #to_log implementations call .compact, dropping nil keys. A JSON client needs a fixed
    # key set: a field that appears and disappears makes every consumer handle two shapes.
    # Naming the three apart is what stops one being quietly changed to suit another.
    class Snapshot < Data.define(:captured_at, :sources, :ledger, :enrichment, :coverage)
      def self.capture(now: Time.current, configuration: Github.configuration)
        budget = GithubApiBudget.find_by(id: GithubApiBudget::SINGLETON_ID)
        runs = latest_runs

        new(
          captured_at: now,
          sources: EventSource.order(:id).map do |event_source|
            SourceState.from(event_source, budget: budget,
                                           last_run: runs[event_source.id], now: now)
          end,
          ledger: LedgerState.from(budget, configuration: configuration),
          enrichment: Enrichment::Summary.capture(now: now, configuration: configuration,
                                                  budget: budget),
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

      # §11's key set, in §11's order: poll state, ledger state, then the enrichment
      # counters and coverage percentages.
      #
      # `null` throughout, never a sentinel string and never a missing key. §16's rule is
      # that an unknown must not read as a zero, and the way to honour that in JSON is not
      # to swap the type — a `remaining` that is sometimes an Integer and sometimes
      # "not yet initialized" forces every consumer to type-check. It is: a counted zero
      # prints 0, a number that does not exist prints null, and wherever null would carry
      # two meanings the disambiguating fact gets its own field — ledger.present, due_now,
      # claimable_now.
      def payload
        { captured_at: Ingestion::Report.timestamp(captured_at),
          sources: sources.map(&:payload),
          ledger: ledger.payload,
          enrichment: enrichment_payload,
          coverage: coverage.payload }
      end

      private

      # Each entity class exposes the durable backlog separately from its raw status
      # counts. A backlog row may be temporarily deferred by retry backoff, so this number
      # intentionally differs from claimable_now. Queue depth is not published:
      # jobs are bounded wake-up hints and entity rows are the source of truth.
      def enrichment_payload
        { actors: entity_counts(enrichment.actor_counts,
                                backlog_count: enrichment.actor_backlog_count,
                                oldest_pending_at: enrichment.actor_oldest_pending_at,
                                oldest_pending_age_seconds:
                                  enrichment.actor_oldest_pending_age_seconds),
          repositories: entity_counts(
            enrichment.repository_counts,
            backlog_count: enrichment.repository_backlog_count,
            oldest_pending_at: enrichment.repository_oldest_pending_at,
            oldest_pending_age_seconds: enrichment.repository_oldest_pending_age_seconds
          ),
          claimable_now: enrichment.claimable_now,
          next_enrichment_at: Ingestion::Report.timestamp(enrichment.next_enrichment_at) }
      end

      # fetch(status, 0) because GROUP BY returns no key for a status with no rows. These
      # zeros are counted, not fabricated: the table was read and held nothing.
      def entity_counts(counts, backlog_count:, oldest_pending_at:,
                        oldest_pending_age_seconds:)
        Enrichable::ENRICHMENT_STATUSES
          .index_with { |status| counts.fetch(status, 0) }
          .symbolize_keys
          .merge(backlog_count: backlog_count,
                 oldest_pending_at: Ingestion::Report.timestamp(oldest_pending_at),
                 oldest_pending_age_seconds: oldest_pending_age_seconds)
      end
    end
  end
end
