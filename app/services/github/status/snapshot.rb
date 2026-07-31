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

      # One statement for every source's latest successful run, rather than one per source:
      # DISTINCT ON collapses to the first row of each event_source_id group, and the ORDER
      # BY is what defines "first". id DESC is the tie-break for two runs that completed in
      # the same microsecond — without it the winner is whichever the plan happened to emit.
      #
      # Matches IngestionRun.latest_successful's definition of success, which includes a
      # 304: the poll succeeded and GitHub reported nothing new.
      def self.latest_runs
        IngestionRun.successful.where.not(completed_at: nil)
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

      # §11's "pending_actor_count / pending_repository_count / skipped_actor_count /
      # skipped_repository_count", and the reason all five statuses are published rather
      # than those two.
      #
      # §11 lists pending_* beside skipped_*, and skipped_budget is a value of
      # Enrichable::ENRICHMENT_STATUSES — so its sibling is the status value too, and
      # `pending` here means enrichment_status = 'pending' exactly.
      # Github::Ingestion::StateSummary uses the same *name* for a different number: the
      # enrichment_candidates scope, which is pending **plus** retryable_failure and is
      # what "still to enrich" means when the question is how much work is left. Both are
      # right for their own question, and publishing one of them under a name the other
      # also uses is how two numbers silently become one. So this block names both:
      # every status by its own name, and the scope as `candidates`.
      def enrichment_payload
        { actors: entity_counts(enrichment.actor_counts),
          repositories: entity_counts(enrichment.repository_counts),
          claimable_now: enrichment.claimable_now,
          next_enrichment_at: Ingestion::Report.timestamp(enrichment.next_enrichment_at) }
      end

      # fetch(status, 0) because GROUP BY returns no key for a status with no rows, and an
      # absent key here would be the missing-key shape the payload rule forbids. These
      # zeros are counted, not fabricated: the table was read and held nothing.
      def entity_counts(counts)
        Enrichable::ENRICHMENT_STATUSES.index_with { |status| counts.fetch(status, 0) }
                                       .symbolize_keys
                                       .merge(candidates: candidates(counts))
      end

      def candidates(counts)
        Enrichable::CANDIDATE_STATUSES.sum { |status| counts.fetch(status, 0) }
      end
    end
  end
end
