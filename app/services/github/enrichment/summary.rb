module Github
  module Enrichment
    # What bin/enrich prints to prove enrichment state, alongside the block bin/ingest
    # already prints (Github::Ingestion::StateSummary), and the /status enrichment block.
    #
    # **It never initiates a GitHub request**, structurally: no executor, no transport,
    # no ledger writer — read statements over Active Record models. Ledger rows are read
    # with find_by rather than through the ledgers, because a read path must not create
    # them.
    class Summary < Data.define(:actor, :repository, :detail_used, :detail_allowance,
                                :actor_share_used, :repository_share_used,
                                :actor_guarantee, :repository_guarantee,
                                :window_status, :window_ready,
                                :search_present, :search_used, :search_spendable,
                                :search_remaining, :search_blocked_until, :next_search_at,
                                :work_waiting, :claimable_now, :next_enrichment_at)
      NO_LEDGER = "not yet initialized".freeze
      DUE_NOW = "due now".freeze
      WAITING_FOR_WINDOW = "waiting for authoritative poll".freeze

      # next_enrichment_at is nil in two states that are not the same fact: something is
      # claimable *right now*, and nothing will ever become claimable without new ingest
      # activity. claimable_now is the member that separates them; this is the label for
      # the other side.
      NOTHING_WAITING = "nothing waiting".freeze

      class << self
        # @param budget [GithubApiBudget, nil] passed by Github::Status::Snapshot so
        #   /status reads each singleton exactly once — independent find_by calls could
        #   straddle a committing reservation and publish blocks that contradict each
        #   other.
        def capture(now: Time.current, configuration: Github.configuration,
                    budget: GithubApiBudget.find_by(id: GithubApiBudget::SINGLETON_ID),
                    search_budget: GithubSearchBudget.find_by(id: GithubSearchBudget::SINGLETON_ID),
                    backlog: BacklogMetrics.capture(now: now, configuration: configuration),
                    admission: Admission.new(configuration: configuration),
                    batch_claim: BatchClaim.new(configuration: configuration),
                    detail_claim: DetailClaim.new(configuration: configuration))
          guarantees = guarantees_for(budget, configuration)

          search_verdict = admission.search(now: now)
          detail_verdict = admission.detail(now: now)
          batch_work = EntityType.all.select { |type| batch_claim.claimable?(type, now: now) }
          detail_work = EntityType.all.select { |type| detail_claim.claimable?(type, now: now) }

          claimable = (admissible_now?(search_verdict) && batch_work.any?) ||
                      (detail_verdict.granted? && detail_work.any?)
          work_waiting = work_waiting?(backlog)

          new(
            actor: backlog.actor, repository: backlog.repository,
            detail_used: budget&.enrichment_used,
            detail_allowance: budget&.enrichment_allowance,
            actor_share_used: budget&.actor_share_used,
            repository_share_used: budget&.repository_share_used,
            actor_guarantee: guarantees[:actor], repository_guarantee: guarantees[:repository],
            window_status: budget&.window_status,
            window_ready: detail_verdict.reason != :window_uninitialized &&
                          detail_verdict.reason != :window_elapsed,
            search_present: !search_budget.nil?,
            search_used: search_budget&.used,
            search_spendable: search_budget && (search_budget.request_ceiling - search_budget.reserve),
            search_remaining: search_budget&.remaining,
            search_blocked_until: search_budget&.blocked_until,
            next_search_at: next_search_at(search_verdict, now: now),
            work_waiting: work_waiting,
            claimable_now: claimable,
            next_enrichment_at: claimable ? nil : next_enrichment_at(
              search_verdict, detail_verdict, now: now, work_waiting: work_waiting,
              configuration: configuration
            )
          )
        end

        private

        def guarantees_for(budget, configuration)
          return { actor: nil, repository: nil } if budget.nil?

          Allowances.split(budget.enrichment_allowance, configuration.actor_enrichment_share)
        end

        # Pacing is a wait, not a refusal — a cycle sleeps through it.
        def admissible_now?(search_verdict)
          search_verdict.granted? || search_verdict.reason == :search_pacing
        end

        def next_search_at(search_verdict, now:)
          return nil if search_verdict.granted?
          return nil if search_verdict.retry_in_seconds.nil?

          now + search_verdict.retry_in_seconds
        end

        # The soonest instant at which any staged work could legally proceed: a ledger
        # block or pacing clearing, a retry backoff expiring, a live lease expiring, or
        # the earliest refresh becoming TTL-due. nil when no such instant exists — which
        # with claimable_now false means nothing will happen without new ingest activity.
        def next_enrichment_at(search_verdict, detail_verdict, now:, work_waiting:,
                               configuration:)
          candidates = []

          if work_waiting
            [ search_verdict, detail_verdict ].each do |verdict|
              candidates << now + verdict.retry_in_seconds if verdict.retry_in_seconds
            end
          end

          EntityType.all.each do |type|
            model = type.model
            candidates << model.where.not(enrichment_stage: "terminal")
                               .where(next_retry_at: now...).minimum(:next_retry_at)
            candidates << model.where(leased_until: now...).minimum(:leased_until)
            candidates << earliest_refresh_at(type, now: now, configuration: configuration)
          end

          candidates.compact.min
        end

        # The instant the oldest eligible completed row crosses its TTL. Only the
        # fetched_at clock matters here; activity eligibility is applied in the scope.
        def earliest_refresh_at(type, now:, configuration:)
          oldest_fetched = type.model
                               .where(enrichment_status: "complete",
                                      enrichment_stage: "contract_complete")
                               .where(last_seen_at: (now - configuration.refresh_active_within_seconds)..)
                               .minimum(:fetched_at)
          return nil if oldest_fetched.nil?

          due_at = oldest_fetched + type.refresh_ttl_seconds(configuration)
          [ due_at, now ].max
        end

        def work_waiting?(backlog)
          [ backlog.actor, backlog.repository ].any? do |entry|
            entry.contract_backlog_count.positive? ||
              entry.stage_counts.values.sum > entry.stage_counts.fetch("terminal", 0)
          end
        end
      end

      def to_s
        [
          Ingestion::Report.line("Actor contract backlog",
                                 Ingestion::Report.count(actor.contract_backlog_count)),
          Ingestion::Report.line("Repository contract backlog",
                                 Ingestion::Report.count(repository.contract_backlog_count)),
          Ingestion::Report.line("Oldest actor pending",
                                 oldest_pending(actor.oldest_pending_at,
                                                actor.oldest_pending_age_seconds)),
          Ingestion::Report.line("Oldest repository pending",
                                 oldest_pending(repository.oldest_pending_at,
                                                repository.oldest_pending_age_seconds)),
          Ingestion::Report.line("Search budget", search_line),
          Ingestion::Report.line("Detail fallback budget",
                                 backlog_budget(detail_used, detail_allowance)),
          Ingestion::Report.line("Detail actor share", share_line(actor_share_used, actor_guarantee)),
          Ingestion::Report.line("Detail repository share",
                                 share_line(repository_share_used, repository_guarantee)),
          Ingestion::Report.line("Next enrichment attempt", next_enrichment)
        ].join("\n")
      end

      def to_log
        { actor_counts: actor.status_counts, repository_counts: repository.status_counts,
          actor_stage_counts: actor.stage_counts,
          repository_stage_counts: repository.stage_counts,
          actor_contract_backlog_count: actor.contract_backlog_count,
          repository_contract_backlog_count: repository.contract_backlog_count,
          actor_oldest_pending_at: Ingestion::Report.timestamp(actor.oldest_pending_at),
          repository_oldest_pending_at: Ingestion::Report.timestamp(repository.oldest_pending_at),
          detail_used: detail_used, detail_allowance: detail_allowance,
          actor_share_used: actor_share_used, repository_share_used: repository_share_used,
          search_used: search_used, search_spendable: search_spendable,
          search_remaining: search_remaining,
          search_blocked_until: Ingestion::Report.timestamp(search_blocked_until),
          next_search_at: Ingestion::Report.timestamp(next_search_at),
          window_status: window_status, claimable_now: claimable_now,
          next_enrichment_at: Ingestion::Report.timestamp(next_enrichment_at) }.compact
      end

      private

      def oldest_pending(timestamp, age_seconds)
        return NOTHING_WAITING if timestamp.nil?

        "#{Ingestion::Report.timestamp(timestamp)} (#{Ingestion::Report.count(age_seconds)}s old)"
      end

      # NO_LEDGER for the same reason StateSummary spells its unknowns out: a fabricated
      # zero on a fresh install would claim a quota window had been observed when it had
      # not. The search row is different — it is configuration-born, so "not yet
      # initialized" simply means no search request has ever been attempted.
      def share_line(used, allowance)
        return NO_LEDGER if used.nil?

        "#{Ingestion::Report.count(used)} of #{Ingestion::Report.count(allowance)}"
      end

      def backlog_budget(used, allowance)
        value = share_line(used, allowance)

        value == NO_LEDGER ? value : "#{value} used"
      end

      def search_line
        return NO_LEDGER unless search_present

        line = "#{Ingestion::Report.count(search_used)} of " \
               "#{Ingestion::Report.count(search_spendable)} spendable used"
        line += ", next request #{Ingestion::Report.timestamp(next_search_at)}" if next_search_at
        line
      end

      # Three answers, not two. A nil instant means "no deferral applies", which is true
      # both when work is claimable this second and when the backlog is empty — and an
      # operator reads those two states completely differently.
      def next_enrichment
        return DUE_NOW if claimable_now
        return NOTHING_WAITING unless work_waiting
        return WAITING_FOR_WINDOW unless window_ready || search_present
        return NOTHING_WAITING if next_enrichment_at.nil?

        Ingestion::Report.timestamp(next_enrichment_at)
      end
    end
  end
end
