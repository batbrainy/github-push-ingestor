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
        connection = model.connection
        status_column = connection.quote_column_name(:enrichment_status)
        created_at_column = connection.quote_column_name(:created_at)
        candidate_values = Enrichable::CANDIDATE_STATUSES.map do |status|
          connection.quote(status)
        end.join(", ")
        candidate_filter = "#{status_column} IN (#{candidate_values})"

        STATUSES.map do |status|
          quoted_status = connection.quote(status)
          Arel.sql("COUNT(*) FILTER (WHERE #{status_column} = #{quoted_status})")
        end + [
          Arel.sql("COUNT(*) FILTER (WHERE #{candidate_filter})"),
          Arel.sql("MIN(#{created_at_column}) FILTER (WHERE #{candidate_filter})")
        ]
      end
      private_class_method :aggregate_columns

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
