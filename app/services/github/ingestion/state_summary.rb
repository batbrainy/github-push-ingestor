module Github
  module Ingestion
    # What the one-shot prints to prove system state (IMPLEMENTATION_PLAN.md §9).
    #
    # §9: "Its stdout always proves system state, even when deferred or busy." So this
    # cannot be a projection of a run result — on the busy path no run happened at all. It
    # is a snapshot of what is persisted, taken from five statements and nothing else.
    #
    # **It never initiates a GitHub request**, the same guarantee §11 places on /status, and
    # it is structural rather than a promise: the class holds no executor, no transport and
    # no ledger, and its only collaborators are Active Record models. Two specs pin it — the
    # fixture transport records every request it is asked for and must have none, and the
    # ledger row count must not change, which also catches the subtler mistake of calling
    # BudgetLedger#bootstrap! from a read path.
    #
    # Splitting the snapshot from its rendering is what lets a spec assert §9's "1,284"
    # delimiter without inserting 1,284 rows, and it is the seam PR 10's /status consumes
    # while the one-shot consumes #to_s.
    class StateSummary < Data.define(
      :latest_run_at, :latest_run_id, :push_event_count,
      :pending_actor_count, :pending_repository_count,
      :budget_resource, :budget_remaining, :budget_reset_at, :window_status
    )
      NONE_YET = "none yet".freeze
      NO_LEDGER = "not yet initialized".freeze
      UNKNOWN_REMAINING = "unknown (window uninitialized)".freeze

      def self.capture
        latest_run_at, latest_run_id = IngestionRun.latest_successful.pick(:completed_at, :run_id)
        resource, remaining, reset_at, window_status =
          GithubApiBudget.where(id: GithubApiBudget::SINGLETON_ID)
                         .pick(:resource, :remaining, :reset_at, :window_status)

        new(
          latest_run_at: latest_run_at, latest_run_id: latest_run_id,
          push_event_count: PushEvent.count,
          # The scope whose WHERE clause matches index_*_on_enrichment_candidates exactly, so
          # both counts are partial-index counts. In PR 5 it is numerically identical to
          # "pending", because nothing transitions an entity until PR 7; §11's finer
          # pending/skipped split arrives with PR 10's /status.
          pending_actor_count: GithubActor.enrichment_candidates.count,
          pending_repository_count: GithubRepository.enrichment_candidates.count,
          budget_resource: resource, budget_remaining: remaining, budget_reset_at: reset_at,
          window_status: window_status
        )
      end

      # §9's block, and the reason every "unknown" below is spelled out rather than printed
      # as 0: §16 forbids a misleading guarantee, and a fabricated zero on a fresh install is
      # exactly one.
      def to_s
        [
          Report.line("Latest successful run", latest_run),
          Report.line("Persisted push events", Report.count(push_event_count)),
          Report.line("Pending actor enrichments", Report.count(pending_actor_count)),
          Report.line("Pending repository enrichments", Report.count(pending_repository_count)),
          Report.line("Budget remaining (#{budget_resource || "core"})", budget)
        ].join("\n")
      end

      def to_log
        to_h.merge(latest_run_at: Report.timestamp(latest_run_at),
                   budget_reset_at: Report.timestamp(budget_reset_at)).compact
      end

      private

      def latest_run
        return NONE_YET if latest_run_at.nil?

        "#{Report.timestamp(latest_run_at)} (run_id #{latest_run_id})"
      end

      # Three states, not two. No row at all means nothing has reserved yet — the ledger row
      # is created by the first reservation, never by a read. A row whose remaining is NULL
      # means the window is open but not yet initialized from authoritative headers, which
      # §7 is explicit about: "never assume 60 remaining".
      def budget
        return NO_LEDGER if window_status.nil?
        return UNKNOWN_REMAINING if budget_remaining.nil?

        reset = budget_reset_at ? " (window resets #{Report.timestamp(budget_reset_at)})" : ""

        "#{Report.count(budget_remaining)}#{reset}"
      end
    end
  end
end
