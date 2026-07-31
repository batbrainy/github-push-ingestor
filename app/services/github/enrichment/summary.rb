module Github
  module Enrichment
    # What bin/enrich prints to prove enrichment state, alongside the block bin/ingest
    # already prints (Github::Ingestion::StateSummary).
    #
    # A second object rather than more members on that one, because the two answer
    # different questions and §13 splits them across two PRs: StateSummary is §9's
    # proof-of-state for the *polling* command, and §11 assigns the coverage percentages to
    # PR 10's /status. What lands here is the part PR 7's own outcome would otherwise be
    # invisible without — the per-status counts and the per-class share usage §10 defines.
    # The percentages themselves are Github::Enrichment::Coverage, which needs
    # ENRICHMENT_COVERAGE_WINDOW_SECONDS and a join against push_events; both arrived with
    # PR 10, and /status renders the two objects side by side.
    #
    # **It never initiates a GitHub request**, structurally and for StateSummary's reason:
    # no executor, no transport, no ledger — three read statements over Active Record
    # models. Reading the ledger row with find_by rather than through
    # Github::BudgetLedger matters for the same reason PollSchedule gives: a read path must
    # not create the row.
    class Summary < Data.define(:actor_counts, :repository_counts, :actor_share_used,
                                :repository_share_used, :actor_guarantee,
                                :repository_guarantee, :enrichment_used,
                                :enrichment_allowance, :window_status, :claimable_now,
                                :next_enrichment_at)
      NO_LEDGER = "not yet initialized".freeze
      DUE_NOW = "due now".freeze

      # next_enrichment_at is nil in two states that are not the same fact: something is
      # claimable *right now*, and nothing will ever become claimable without new ingest
      # activity. Printing "due now" for both was wrong on an empty backlog — bin/enrich
      # would say work was due in the same breath it reported nothing to enrich — and
      # publishing the same nil as JSON would hand /status's consumers the identical
      # ambiguity. claimable_now is the member that separates them; this is the label for
      # the other side.
      NOTHING_WAITING = "nothing waiting".freeze

      # The three statuses an operator acts on. permanent_failure and retryable_failure are
      # rolled into the pending/complete/skipped triple's remainder rather than printed
      # separately: §11's line is "pending/skipped counts", and a five-column row would
      # bury the two numbers that describe the sampling rate.
      REPORTED_STATUSES = %w[ pending complete skipped_budget ].freeze

      class << self
        # @param budget [GithubApiBudget, nil] the ledger row, when the caller already holds
        #   it. Github::Status::Snapshot passes one so /status reads the singleton exactly
        #   once: three independent find_by calls could straddle a committing reservation
        #   and produce one response whose poll block contradicts its ledger block. The
        #   default keeps every existing caller reading it here, and keeps reading it with
        #   find_by rather than through Github::BudgetLedger, because a read path must not
        #   create the row.
        def capture(now: Time.current, configuration: Github.configuration,
                    selector: CandidateSelector.new(configuration: configuration),
                    budget: GithubApiBudget.find_by(id: GithubApiBudget::SINGLETON_ID))
          guarantees = guarantees_for(budget, configuration)
          claimable = claimable_now?(budget, selector, now: now)

          new(
            actor_counts: counts(GithubActor),
            repository_counts: counts(GithubRepository),
            actor_share_used: budget&.actor_share_used,
            repository_share_used: budget&.repository_share_used,
            actor_guarantee: guarantees[:actor], repository_guarantee: guarantees[:repository],
            enrichment_used: budget&.enrichment_used,
            enrichment_allowance: budget&.enrichment_allowance,
            window_status: budget&.window_status,
            claimable_now: claimable,
            next_enrichment_at: next_enrichment_at(budget, selector, claimable, now: now)
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
        # nil when something is claimable right now, otherwise the soonest instant at which
        # something will be.
        #
        # Both pools, and the claimable question asked first. Reading "due now" off an
        # absent *pending* retry instant was wrong three ways, and all three are states the
        # deterministic fixture run reaches: a fully enriched backlog reported "due now"
        # while `bin/enrich` in the same breath reported nothing to enrich, because the next
        # legal action was a refresh at fetched_at + TTL and nothing looked there; a
        # complete row deferred by a failed refresh was invisible for the same reason; and
        # one candidate due now beside one deferred printed the deferred instant while work
        # was in fact claimable.
        def next_enrichment_at(budget, selector, claimable, now:)
          blocked = blocked_until(budget, now: now)
          return blocked if blocked
          return nil if claimable

          EntityType.all.filter_map { |type| selector.earliest_claimable_at(type, now: now) }.min
        end

        # "A request would be issued if the runner ran right now." Both pools, and the
        # ledger asked first: a global block or a spent class outranks every per-entity
        # instant, and is the one case where the answer exists without reading an entity
        # row at all.
        def claimable_now?(budget, selector, now:)
          return false if blocked_until(budget, now: now)

          EntityType.all.any? { |type| selector.claimable?(type, now: now) }
        end

        # nil unless the instant is genuinely still ahead: BudgetLedger derives blocking
        # from the timestamp rather than from the label precisely so an expired one cannot
        # strand the row, and this reader has to agree with it.
        def blocked_until(budget, now:)
          blocked = [ budget&.global_blocked_until,
                      budget&.enrichment_class_blocked_until(now: now) ].compact.max

          blocked if blocked&.>(now)
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
          window_status: window_status, claimable_now: claimable_now,
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

      # Three answers, not two. A nil instant means "no deferral applies", which is true
      # both when a candidate is claimable this second and when the backlog is empty —
      # and an operator reads those two states completely differently. claimable_now is
      # what tells them apart; without it this line said "due now" to a reviewer whose
      # very next line of output was "nothing to enrich".
      def next_enrichment
        return DUE_NOW if claimable_now
        return NOTHING_WAITING if next_enrichment_at.nil?

        Ingestion::Report.timestamp(next_enrichment_at)
      end
    end
  end
end
