module Github
  module Enrichment
    # Read-only measurements of the durable, eventually processed enrichment backlog.
    #
    # Solid Queue contains only bounded wake-up hints. The rows in github_actors and
    # github_repositories are the source of truth, so queue depth would under-report work by
    # design. This projection counts the same candidate statuses as
    # Enrichable.enrichment_candidates, including work deferred by retry backoff, and reports
    # how long the oldest row has waited — plus, per issue #45, the staged-pipeline view:
    # per-stage counts with each stage's oldest FIFO instant, the contract backlog, and the
    # windowed arrival/completion/terminal counts the catch-up verdict is computed from.
    #
    # No claim scope is used here: claim scopes answer "claimable now" and exclude a
    # deferred row. Backlog observability answers the different question "what work must the
    # service eventually finish?" and therefore must include every backlog entity.
    #
    # Everything for one entity table comes from ONE aggregate statement. A worker may
    # commit between statements, so separate reads could publish a combination of numbers
    # that never existed in the database at any instant. The statement is a single
    # sequential scan however many conditional aggregates ride on it; revisit with partial
    # indexes on contract_completed_at / terminal_at only if the tables reach millions of
    # rows.
    class BacklogMetrics < Data.define(:actor, :repository, :window_seconds)
      Entry = Data.define(:status_counts, :stage_counts, :stage_oldest,
                          :backlog_count, :contract_backlog_count,
                          :oldest_pending_at, :oldest_pending_age_seconds,
                          :arrivals, :completions, :terminals, :earliest_created_at)

      STATUSES = Enrichable::ENRICHMENT_STATUSES
      STAGES = Enrichable::ENRICHMENT_STAGES

      def self.capture(now: Time.current, configuration: Github.configuration)
        window_seconds = configuration.enrichment_metrics_window_seconds
        floor = now - window_seconds

        new(actor: entry_for(GithubActor, now: now, floor: floor),
            repository: entry_for(GithubRepository, now: now, floor: floor),
            window_seconds: window_seconds)
      end

      def self.entry_for(model, now:, floor:)
        # The claim's FIFO order is created_at, the immutable instant the entity entered
        # this backlog. Reporting the same clock keeps "oldest" aligned with the row the
        # worker will actually choose next.
        values = Array(model.unscoped.pick(*aggregate_columns(model, floor: floor)))

        status_counts = STATUSES.zip(values.shift(STATUSES.length)).to_h
                                .transform_values(&:to_i)
                                .reject { |_status, count| count.zero? }
        # Stage counts keep their zeros: the payload publishes every stage so a consumer
        # never has to distinguish "absent key" from "counted zero".
        stage_counts = STAGES.zip(values.shift(STAGES.length)).to_h.transform_values(&:to_i)
        stage_oldest = STAGES.zip(values.shift(STAGES.length)).to_h

        backlog_count = values.shift.to_i
        oldest = values.shift
        contract_backlog_count = values.shift.to_i
        arrivals = values.shift.to_i
        completions = values.shift.to_i
        terminals = values.shift.to_i
        earliest_created_at = values.shift

        Entry.new(status_counts: status_counts, stage_counts: stage_counts,
                  stage_oldest: stage_oldest,
                  backlog_count: backlog_count,
                  contract_backlog_count: contract_backlog_count,
                  oldest_pending_at: oldest,
                  oldest_pending_age_seconds: age_seconds(oldest, now: now),
                  arrivals: arrivals, completions: completions, terminals: terminals,
                  earliest_created_at: earliest_created_at)
      end
      private_class_method :entry_for

      def self.aggregate_columns(model, floor:)
        table = model.arel_table
        status_column = table[:enrichment_status]
        stage_column = table[:enrichment_stage]
        candidate_filter = status_column.in(Enrichable::CANDIDATE_STATUSES)
        # Contract debt: not yet at the useful-data contract or a terminal outcome, and
        # not a completed row transiting a refresh — the same rule Appendix G states.
        contract_filter = stage_column.not_in(%w[contract_complete terminal])
                                      .and(status_column.not_eq("complete"))
        bound = ->(value) { Arel::Nodes.build_quoted(value) }

        STATUSES.map { |status| count_if(status_column.eq(status)) } +
          STAGES.map { |stage| count_if(stage_column.eq(stage)) } +
          STAGES.map { |stage| minimum_if(stage_column.eq(stage), table[:created_at]) } +
          [
            count_if(candidate_filter),
            minimum_if(candidate_filter, table[:created_at]),
            count_if(contract_filter),
            count_if(table[:created_at].gt(bound.call(floor))),
            count_if(table[:contract_completed_at].gt(bound.call(floor))),
            count_if(table[:terminal_at].gt(bound.call(floor))),
            Arel::Nodes::NamedFunction.new("MIN", [ table[:created_at] ])
          ]
      end
      private_class_method :aggregate_columns

      # Build conditional aggregates as Arel nodes instead of interpolating quoted SQL.
      # COUNT ignores the implicit NULL for rows that do not match the CASE predicate.
      def self.count_if(predicate)
        conditional = Arel::Nodes::Case.new.when(predicate).then(1)

        Arel::Nodes::NamedFunction.new("COUNT", [ conditional ])
      end
      private_class_method :count_if

      def self.minimum_if(predicate, value)
        conditional = Arel::Nodes::Case.new.when(predicate).then(value)

        Arel::Nodes::NamedFunction.new("MIN", [ conditional ])
      end
      private_class_method :minimum_if

      # A database timestamp a fraction ahead of the application clock can occur around a
      # snapshot boundary. A negative backlog age is never useful, so clamp that harmless
      # skew to zero while retaining whole-second precision for an operator-facing metric.
      def self.age_seconds(timestamp, now:)
        return nil if timestamp.nil?

        [ (now - timestamp).floor, 0 ].max
      end
    end
  end
end
