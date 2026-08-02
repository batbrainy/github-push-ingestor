module Github
  module Enrichment
    # Read-only measurements of the durable, eventually processed enrichment backlog.
    #
    # Solid Queue contains only bounded wake-up hints. The rows in github_actors and
    # github_repositories are the source of truth, so queue depth would under-report work by
    # design. This projection counts the same candidate statuses as
    # Enrichable.enrichment_candidates, including work deferred by retry backoff, and reports
    # how long the oldest row has waited.
    #
    # No selector is used here: selector scopes answer "claimable now" and may exclude a
    # deferred row. Backlog observability answers the different question "what work must the
    # service eventually finish?" and therefore must include every backlog entity.
    class BacklogMetrics < Data.define(:actor, :repository)
      Entry = Data.define(:status_counts, :backlog_count, :oldest_pending_at,
                          :oldest_pending_age_seconds)

      STATUSES = Enrichable::ENRICHMENT_STATUSES

      def self.capture(now: Time.current)
        new(actor: entry_for(GithubActor, now: now),
            repository: entry_for(GithubRepository, now: now))
      end

      def self.entry_for(model, now:)
        # CandidateSelector's FIFO order is created_at, the immutable instant the entity
        # entered this backlog. Reporting the same clock keeps "oldest" aligned with the
        # row the worker will actually choose next.
        #
        # All status counts, the candidate count, and its oldest row come from one aggregate
        # statement. A worker may commit between statements, so separate count/minimum reads
        # could otherwise publish a combination that never existed in the database.
        values = Array(model.unscoped.pick(*aggregate_columns(model)))
        status_counts = STATUSES.zip(values.shift(STATUSES.length)).to_h
                                .transform_values(&:to_i)
                                .reject { |_status, count| count.zero? }
        backlog_count = values.shift.to_i
        oldest = values.shift

        Entry.new(status_counts: status_counts,
                  backlog_count: backlog_count,
                  oldest_pending_at: oldest,
                  oldest_pending_age_seconds: age_seconds(oldest, now: now))
      end
      private_class_method :entry_for

      def self.aggregate_columns(model)
        table = model.arel_table
        status_column = table[:enrichment_status]
        candidate_filter = status_column.in(Enrichable::CANDIDATE_STATUSES)

        STATUSES.map do |status|
          count_if(status_column.eq(status))
        end + [
          count_if(candidate_filter),
          minimum_if(candidate_filter, table[:created_at])
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
      private_class_method :age_seconds
    end
  end
end
