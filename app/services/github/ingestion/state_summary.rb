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
    # delimiter without inserting 1,284 rows, and it is the *pattern* PR 10's /status
    # adopted — a read-only value object with .capture and no collaborator that writes —
    # while the one-shot consumes #to_s.
    #
    # /status does not consume this class, and deliberately. Github::Status::Snapshot reads
    # the ledger row once and passes it into all three of its parts; composing this object
    # with Github::Enrichment::Summary would read the singleton twice more, so a reservation
    # committing mid-request could produce one response whose poll block contradicted its
    # ledger block. It also collapses PollSchedule to a single instant, where §11 asks for
    # the components.
    #
    # One name means two numbers across the two objects, and both are correct for their own
    # question. pending_actor_count here is the enrichment_candidates scope — pending *plus*
    # retryable_failure, which is what "still to enrich" means for the operator about to run
    # bin/enrich. /status reports the literal status under that name and publishes the scope
    # beside it as `candidates`, because a JSON consumer has no §9 context to disambiguate
    # from.
    class StateSummary < Data.define(
      :latest_run_at, :latest_run_id, :push_event_count,
      :pending_actor_count, :pending_repository_count,
      :budget_resource, :budget_remaining, :budget_reset_at, :window_status,
      :source_present, :next_poll_at, :global_blocked_until
    )
      NONE_YET = "none yet".freeze
      NO_LEDGER = "not yet initialized".freeze
      UNKNOWN_REMAINING = "unknown (window uninitialized)".freeze
      NO_SOURCE = "not yet provisioned".freeze
      DUE_NOW = "due now".freeze
      NO_BLOCK = "none".freeze

      def self.capture(now: Time.current)
        latest_run_at, latest_run_id = IngestionRun.latest_successful.pick(:completed_at, :run_id)
        budget = GithubApiBudget.find_by(id: GithubApiBudget::SINGLETON_ID)
        event_source = EventSource.order(:id).first

        new(
          latest_run_at: latest_run_at, latest_run_id: latest_run_id,
          push_event_count: PushEvent.count,
          # The scope whose WHERE clause matches index_*_on_enrichment_candidates exactly, so
          # both counts are partial-index counts. It counts pending *and* retryable_failure,
          # which is what "still to enrich" means; Github::Enrichment::Summary prints the
          # per-status split that bin/enrich needs, and §11's coverage percentages arrive
          # with PR 10's /status.
          pending_actor_count: GithubActor.enrichment_candidates.count,
          pending_repository_count: GithubRepository.enrichment_candidates.count,
          budget_resource: budget&.resource, budget_remaining: budget&.remaining,
          budget_reset_at: budget&.reset_at, window_status: budget&.window_status,
          source_present: !event_source.nil?,
          next_poll_at: next_poll_at(event_source, budget, now: now),
          global_blocked_until: budget&.global_blocked_until
        )
      end

      # §9's unforced answer, the one the operator's next command will be judged against.
      # A pure computation over two rows that were read anyway, so the class keeps its
      # structural guarantee: no executor, no transport, no ledger, and nothing that
      # writes.
      def self.next_poll_at(event_source, budget, now:)
        return nil if event_source.nil?

        PollSchedule.for(event_source: event_source, budget: budget, now: now).effective_poll_time
      end
      private_class_method :next_poll_at

      # §9's block, and the reason every "unknown" below is spelled out rather than printed
      # as 0: §16 forbids a misleading guarantee, and a fabricated zero on a fresh install is
      # exactly one.
      def to_s
        [
          Report.line("Latest successful run", latest_run),
          Report.line("Persisted push events", Report.count(push_event_count)),
          Report.line("Pending actor enrichments", Report.count(pending_actor_count)),
          Report.line("Pending repository enrichments", Report.count(pending_repository_count)),
          # Two scheduling lines, and no more. The busy path is what earns them: on
          # Errors::SourceBusy no run happened, so there is no deferral line at all and
          # this block is the only place a reviewer can learn when the next poll is or why
          # nothing is moving. §11 assigns the per-class counters, the coverage formulas,
          # and the individual scheduling components to PR 10's /status.
          Report.line("Next poll due", next_poll),
          Report.line("Budget remaining (#{budget_resource || "core"})", budget),
          Report.line("Global block", global_block)
        ].join("\n")
      end

      def to_log
        to_h.merge(latest_run_at: Report.timestamp(latest_run_at),
                   budget_reset_at: Report.timestamp(budget_reset_at),
                   next_poll_at: Report.timestamp(next_poll_at),
                   global_blocked_until: Report.timestamp(global_blocked_until)).compact
      end

      private

      # A source that has never been polled has five nil components, so nil means "no
      # constraint applies" rather than "unknown" — the same meaning it carries in
      # PollSchedule, spelled out here so the reviewer does not have to infer it.
      def next_poll
        return NO_SOURCE unless source_present
        return DUE_NOW if next_poll_at.nil?

        Report.timestamp(next_poll_at)
      end

      # Reported separately from window_status because the two answer different questions:
      # a block can outlive the window that produced it, and BudgetLedger derives blocking
      # from this timestamp alone precisely so an expired label can never strand the row.
      # Without this line, a window_status of globally_blocked has no explanation on
      # stdout.
      def global_block
        return NO_BLOCK if global_blocked_until.nil?

        "until #{Report.timestamp(global_blocked_until)}"
      end

      def no_source?
        !EventSource.exists?
      end

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
