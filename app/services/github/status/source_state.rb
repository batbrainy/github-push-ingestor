module Github
  module Status
    # The poll half of IMPLEMENTATION_PLAN.md §11's /status: "poll state (scheduling
    # components, last run)".
    #
    # One of these per event_sources row. §9's one-shot prints a single block because it
    # runs one command against one source, and Github::Ingestion::StateSummary picks
    # `EventSource.order(:id).first` accordingly — but /status describes the whole
    # installation, and picking one row would name the wrong one in the database reviewers
    # actually build. source_type carries no unique constraint, the README's reviewer path
    # creates a second github_fixture_events row beside the live one, and
    # ENABLED_LIVE_SOURCE_COUNT is an input to §10's allowance formula precisely because
    # more than one live source is a supported configuration. So Snapshot renders an array
    # at every cardinality, including one and zero.
    class SourceState < Data.define(:id, :source_type, :enabled, :status,
                                    :consecutive_failures, :last_polled_at,
                                    :last_success_at, :schedule, :last_run, :now)
      # @param event_source [EventSource]
      # @param budget [GithubApiBudget, nil] the row Snapshot already read.
      # @param last_run [IngestionRun, nil] this source's most recent successful run.
      # @param now [Time] carried as a member rather than re-read in #payload. One
      #   poll_class_blocked_until is derived from it and one due? compares against it, and
      #   a snapshot whose two halves consulted the clock separately could report a source
      #   both blocked and due.
      def self.from(event_source, budget:, last_run:, now:)
        new(id: event_source.id, source_type: event_source.source_type,
            enabled: event_source.enabled, status: event_source.status,
            consecutive_failures: event_source.consecutive_failures,
            last_polled_at: event_source.last_polled_at,
            last_success_at: event_source.last_success_at,
            schedule: PollSchedule.for(event_source: event_source, budget: budget, now: now),
            last_run: last_run, now: now)
      end

      # The five components computed live rather than the stored next_poll_at column.
      # Github::Ingestion::PollState is explicit that nothing reads that column back to make
      # a decision, because a cached instant goes stale the moment a block clears — and a
      # status endpoint reporting a stale instant is the same mistake with a wider audience.
      #
      # due_now is emitted beside next_poll_at because nil here means "no constraint
      # applies", not "unknown", and JSON has no way to say which without being told.
      # scheduling_components carries only the constraints in play; binding_component names
      # which of them produced the answer, so an operator changes one thing rather than
      # auditing five.
      def payload
        components = schedule.components

        { id: id, source_type: source_type, enabled: enabled, status: status,
          consecutive_failures: consecutive_failures,
          last_polled_at: Ingestion::Report.timestamp(last_polled_at),
          last_success_at: Ingestion::Report.timestamp(last_success_at),
          due_now: schedule.due?(now: now),
          next_poll_at: Ingestion::Report.timestamp(schedule.effective_poll_time),
          binding_component: schedule.binding_component,
          scheduling_components: PollSchedule::COMPONENTS.index_with do |name|
            Ingestion::Report.timestamp(components[name])
          end,
          last_run: run_payload }
      end

      private

      # nil rather than an all-null object: "this source has never completed a run" is one
      # fact, and spelling it as a nested shape of nulls would invite a consumer to read
      # fields off it.
      def run_payload
        return nil if last_run.nil?

        { run_id: last_run.run_id, status: last_run.status,
          completed_at: Ingestion::Report.timestamp(last_run.completed_at) }
      end
    end
  end
end
