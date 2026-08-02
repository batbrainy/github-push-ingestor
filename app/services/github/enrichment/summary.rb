module Github
  module Enrichment
    # What bin/enrich prints to prove enrichment state, alongside the block bin/ingest
    # already prints (Github::Ingestion::StateSummary).
    #
    # A second object rather than more members on that one, because the two answer
    # different questions and §13 splits them across two PRs: StateSummary is §9's
    # proof-of-state for the *polling* command, and /status owns the coverage percentages.
    # What lands here is the part an enrichment outcome would otherwise leave invisible:
    # the durable per-class backlog, its oldest wait, and reserved allowance usage.
    # The percentages themselves are Github::Enrichment::Coverage, which needs
    # ENRICHMENT_COVERAGE_WINDOW_SECONDS and a join against push_events; both arrived with
    # PR 10, and /status renders the two objects side by side.
    #
    # **It never initiates a GitHub request**, structurally and for StateSummary's reason:
    # no executor, no transport, no ledger — read statements over Active Record
    # models. Reading the ledger row with find_by rather than through
    # Github::BudgetLedger matters for the same reason PollSchedule gives: a read path must
    # not create the row.
    class Summary < Data.define(:actor_counts, :repository_counts,
                                :actor_backlog_count,
                                :repository_backlog_count,
                                :actor_oldest_pending_at, :repository_oldest_pending_at,
                                :actor_oldest_pending_age_seconds,
                                :repository_oldest_pending_age_seconds,
                                :actor_share_used,
                                :repository_share_used, :actor_guarantee,
                                :repository_guarantee, :enrichment_used,
                                :enrichment_allowance, :window_status, :window_ready,
                                :work_waiting, :claimable_now,
                                :next_enrichment_at)
      NO_LEDGER = "not yet initialized".freeze
      DUE_NOW = "due now".freeze
      WAITING_FOR_WINDOW = "waiting for authoritative poll".freeze

      # next_enrichment_at is nil in two states that are not the same fact: something is
      # claimable *right now*, and nothing will ever become claimable without new ingest
      # activity. Printing "due now" for both was wrong on an empty backlog — bin/enrich
      # would say work was due in the same breath it reported nothing to enrich — and
      # publishing the same nil as JSON would hand /status's consumers the identical
      # ambiguity. claimable_now is the member that separates them; this is the label for
      # the other side.
      NOTHING_WAITING = "nothing waiting".freeze

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
                    budget: GithubApiBudget.find_by(id: GithubApiBudget::SINGLETON_ID),
                    backlog: BacklogMetrics.capture(now: now))
          guarantees = guarantees_for(budget, configuration)
          backlog_waiting = backlog.actor.backlog_count.positive? ||
                            backlog.repository.backlog_count.positive?
          work_waiting = backlog_waiting || complete_rows?(backlog)
          claimable = claimable_now?(
            budget, selector, backlog_waiting: backlog_waiting, now: now
          )

          new(
            actor_counts: backlog.actor.status_counts,
            repository_counts: backlog.repository.status_counts,
            actor_backlog_count: backlog.actor.backlog_count,
            repository_backlog_count: backlog.repository.backlog_count,
            actor_oldest_pending_at: backlog.actor.oldest_pending_at,
            repository_oldest_pending_at: backlog.repository.oldest_pending_at,
            actor_oldest_pending_age_seconds: backlog.actor.oldest_pending_age_seconds,
            repository_oldest_pending_age_seconds: backlog.repository.oldest_pending_age_seconds,
            actor_share_used: budget&.actor_share_used,
            repository_share_used: budget&.repository_share_used,
            actor_guarantee: guarantees[:actor], repository_guarantee: guarantees[:repository],
            enrichment_used: budget&.enrichment_used,
            enrichment_allowance: budget&.enrichment_allowance,
            window_status: budget&.window_status,
            window_ready: !window_unavailable?(budget, now: now),
            work_waiting: work_waiting,
            claimable_now: claimable,
            next_enrichment_at: next_enrichment_at(
              budget, selector, claimable, backlog_waiting: backlog_waiting, now: now
            )
          )
        end

        private

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
        def next_enrichment_at(budget, selector, claimable, backlog_waiting:, now:)
          blocked = blocked_until(budget, now: now)
          return blocked if blocked
          return nil if claimable
          return nil if window_unavailable?(budget, now: now)

          # Fairness reserves refresh capacity for the durable first-time backlog. If all
          # of that backlog is in backoff, a stale refresh is not the next legal action;
          # the earliest pending retry is.
          if backlog_waiting
            return EntityType.all.filter_map do |type|
              selector.earliest_pending_at(type, now: now)
            end.min
          end

          EntityType.all.filter_map { |type| selector.earliest_claimable_at(type, now: now) }.min
        end

        # "A request would be issued if the runner ran right now." The ledger is asked
        # first, then the same first-time-before-refresh rule as Fairness: a deferred
        # backlog row suppresses otherwise-due refresh work.
        def claimable_now?(budget, selector, backlog_waiting:, now:)
          return false if blocked_until(budget, now: now)
          return false if window_unavailable?(budget, now: now)

          if backlog_waiting
            EntityType.all.any? { |type| selector.pending_available?(type, now: now) }
          else
            EntityType.all.any? { |type| selector.refresh_available?(type, now: now) }
          end
        end

        # nil unless the instant is genuinely still ahead: BudgetLedger derives blocking
        # from the timestamp rather than from the label precisely so an expired one cannot
        # strand the row, and this reader has to agree with it.
        def blocked_until(budget, now:)
          blocked = [ budget&.global_blocked_until,
                      budget&.enrichment_class_blocked_until(now: now) ].compact.max

          blocked if blocked&.>(now)
        end

        # A missing row is unavailable too: the first attempted reservation would create
        # it, then be denied until a real poll supplies authoritative rate-limit headers.
        # An elapsed window is equivalent: reserve! rolls it to uninitialized before it can
        # authorize enrichment, so only a poll can make the new window usable.
        def window_unavailable?(budget, now:)
          budget.nil? || budget.window_initialized_at.nil? ||
            (budget.reset_at.present? && now >= budget.reset_at)
        end

        def complete_rows?(backlog)
          [ backlog.actor, backlog.repository ].any? do |entry|
            entry.status_counts.fetch("complete", 0).positive?
          end
        end
      end

      def to_s
        [
          Ingestion::Report.line("Actor backlog", Ingestion::Report.count(actor_backlog_count)),
          Ingestion::Report.line("Repository backlog",
                                 Ingestion::Report.count(repository_backlog_count)),
          Ingestion::Report.line("Oldest actor pending",
                                 oldest_pending(actor_oldest_pending_at,
                                                actor_oldest_pending_age_seconds)),
          Ingestion::Report.line("Oldest repository pending",
                                 oldest_pending(repository_oldest_pending_at,
                                                repository_oldest_pending_age_seconds)),
          Ingestion::Report.line("Actor requests used", share_line(actor_share_used, actor_guarantee)),
          Ingestion::Report.line("Repository requests used", share_line(repository_share_used, repository_guarantee)),
          Ingestion::Report.line("Enrichment backlog budget",
                                 backlog_budget(enrichment_used, enrichment_allowance)),
          Ingestion::Report.line("Next enrichment attempt", next_enrichment)
        ].join("\n")
      end

      def to_log
        { actor_counts: actor_counts, repository_counts: repository_counts,
          actor_backlog_count: actor_backlog_count,
          repository_backlog_count: repository_backlog_count,
          actor_oldest_pending_at: Ingestion::Report.timestamp(actor_oldest_pending_at),
          repository_oldest_pending_at: Ingestion::Report.timestamp(repository_oldest_pending_at),
          actor_oldest_pending_age_seconds: actor_oldest_pending_age_seconds,
          repository_oldest_pending_age_seconds: repository_oldest_pending_age_seconds,
          actor_share_used: actor_share_used, repository_share_used: repository_share_used,
          actor_guarantee: actor_guarantee, repository_guarantee: repository_guarantee,
          enrichment_used: enrichment_used, enrichment_allowance: enrichment_allowance,
          window_status: window_status, claimable_now: claimable_now,
          next_enrichment_at: Ingestion::Report.timestamp(next_enrichment_at) }.compact
      end

      private

      def oldest_pending(timestamp, age_seconds)
        return NOTHING_WAITING if timestamp.nil?

        "#{Ingestion::Report.timestamp(timestamp)} (#{Ingestion::Report.count(age_seconds)}s old)"
      end

      # NO_LEDGER for the same reason StateSummary spells its unknowns out: a fabricated
      # zero on a fresh install would claim a quota window had been observed when it had not.
      def share_line(used, allowance)
        return NO_LEDGER if used.nil?

        "#{Ingestion::Report.count(used)} of #{Ingestion::Report.count(allowance)}"
      end

      def backlog_budget(used, allowance)
        value = share_line(used, allowance)

        value == NO_LEDGER ? value : "#{value} used"
      end

      # Three answers, not two. A nil instant means "no deferral applies", which is true
      # both when a candidate is claimable this second and when the backlog is empty —
      # and an operator reads those two states completely differently. claimable_now is
      # what tells them apart; without it this line said "due now" to a reviewer whose
      # very next line of output was "nothing to enrich".
      def next_enrichment
        return DUE_NOW if claimable_now
        return NOTHING_WAITING unless work_waiting
        return WAITING_FOR_WINDOW unless window_ready
        return NOTHING_WAITING if next_enrichment_at.nil?

        Ingestion::Report.timestamp(next_enrichment_at)
      end
    end
  end
end
