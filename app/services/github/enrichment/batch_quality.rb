module Github
  module Enrichment
    # Issue #45's batch-quality metrics: enrichment_batches aggregated over the trailing
    # metrics window, grouped by request_kind x entity_kind. One grouped statement; the
    # four groups are always present in the payload with counted zeros — the table was
    # read and held nothing.
    class BatchQuality < Data.define(:window_seconds, :window_start, :groups)
      Group = Data.define(:attempts, :in_flight, :succeeded, :failed, :deferred,
                          :stale_lease, :requested_items, :returned_items, :valid_items,
                          :missing_items, :invalid_items, :fill_ratio,
                          :incomplete_results_count)

      EMPTY_GROUP = Group.new(
        attempts: 0, in_flight: 0, succeeded: 0, failed: 0, deferred: 0, stale_lease: 0,
        requested_items: 0, returned_items: 0, valid_items: 0, missing_items: 0,
        invalid_items: 0, fill_ratio: nil, incomplete_results_count: 0
      )

      STATUS_COLUMNS = EnrichmentBatch::STATUSES.freeze

      def self.capture(now: Time.current, configuration: Github.configuration)
        window_seconds = configuration.enrichment_metrics_window_seconds
        floor = now - window_seconds

        rows = EnrichmentBatch.where(started_at: floor..)
                              .group(:request_kind, :entity_kind)
                              .pluck(:request_kind, :entity_kind, *aggregates)

        groups = EnrichmentBatch::REQUEST_KINDS.index_with do |kind|
          EnrichmentBatch::ENTITY_KINDS.index_with { EMPTY_GROUP }
        end
        rows.each do |row|
          kind, entity_kind, *values = row
          groups[kind][entity_kind] = group_from(values)
        end

        new(window_seconds: window_seconds, window_start: floor, groups: groups)
      end

      def self.aggregates
        table = EnrichmentBatch.arel_table
        star = Arel.star

        [ Arel::Nodes::NamedFunction.new("COUNT", [ star ]) ] +
          STATUS_COLUMNS.map { |status| count_filter(table[:status].eq(status)) } +
          %i[requested_count returned_count valid_count missing_count invalid_count].map do |column|
            Arel::Nodes::NamedFunction.new(
              "COALESCE", [ Arel::Nodes::NamedFunction.new("SUM", [ table[column] ]),
                            Arel::Nodes.build_quoted(0) ]
            )
          end + [ count_filter(table[:incomplete_results].eq(true)) ]
      end
      private_class_method :aggregates

      # COUNT(CASE WHEN ...) rather than FILTER, matching the BacklogMetrics idiom.
      def self.count_filter(predicate)
        conditional = Arel::Nodes::Case.new.when(predicate).then(1)

        Arel::Nodes::NamedFunction.new("COUNT", [ conditional ])
      end
      private_class_method :count_filter

      def self.group_from(values)
        attempts = values.shift.to_i
        statuses = STATUS_COLUMNS.map { values.shift.to_i }
        requested, returned, valid, missing, invalid = Array.new(5) { values.shift.to_i }
        incomplete = values.shift.to_i

        Group.new(
          attempts: attempts,
          in_flight: statuses[0], succeeded: statuses[1], failed: statuses[2],
          deferred: statuses[3], stale_lease: statuses[4],
          requested_items: requested, returned_items: returned, valid_items: valid,
          missing_items: missing, invalid_items: invalid,
          # A ratio with a zero denominator is null, never 0.0; the denominator is
          # published beside it so the division is checkable.
          fill_ratio: requested.zero? ? nil : (returned.to_f / requested).round(3),
          incomplete_results_count: incomplete
        )
      end
      private_class_method :group_from

      def payload
        {
          window_seconds: window_seconds,
          window_start: Ingestion::Report.timestamp(window_start),
          search: kind_payload("search"),
          detail: kind_payload("detail")
        }
      end

      private

      def kind_payload(kind)
        {
          actors: groups.fetch(kind).fetch("actor").to_h,
          repositories: groups.fetch(kind).fetch("repository").to_h
        }
      end
    end
  end
end
