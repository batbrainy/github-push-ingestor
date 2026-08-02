module Github
  module Enrichment
    # What one `bin/enrich` invocation did, across however many requests it ran.
    #
    # Immutable, like Github::Ingestion::Tally: #record returns a new value rather than
    # mutating, so a partially accumulated count can never be observed and a caller cannot
    # hold a stale reference that later changes underneath it.
    class Tally < Data.define(:requests, :batches_completed, :batches_failed,
                              :items_requested, :items_valid, :fallbacks_admitted,
                              :details_completed, :details_terminal, :details_retrying,
                              :deferred, :idle, :lease_lost)
      def self.empty
        new(requests: 0, batches_completed: 0, batches_failed: 0,
            items_requested: 0, items_valid: 0, fallbacks_admitted: 0,
            details_completed: 0, details_terminal: 0, details_retrying: 0,
            deferred: 0, idle: 0, lease_lost: 0)
      end

      # @param result [BatchRunner::Result]
      def record_batch(result)
        case result.status
        when "completed"
          with(requests: requests + 1, batches_completed: batches_completed + 1,
               items_requested: items_requested + result.requested_count,
               items_valid: items_valid + result.valid_count,
               fallbacks_admitted: fallbacks_admitted + result.fallback_count)
        when "failed"
          with(requests: requests + 1, batches_failed: batches_failed + 1,
               items_requested: items_requested + result.requested_count)
        when "deferred" then with(requests: requests + 1, deferred: deferred + 1)
        when "idle" then with(idle: idle + 1)
        else raise ArgumentError, "unknown batch status #{result.status.inspect}"
        end
      end

      # @param result [DetailRunner::Result]
      def record_detail(result)
        case result.status
        when "completed" then with(requests: requests + 1, details_completed: details_completed + 1)
        when "terminal" then with(requests: requests + 1, details_terminal: details_terminal + 1)
        when "retry_scheduled" then with(requests: requests + 1, details_retrying: details_retrying + 1)
        when "deferred" then with(requests: requests + 1, deferred: deferred + 1)
        when "lease_lost" then with(requests: requests + 1, lease_lost: lease_lost + 1)
        when "idle" then with(idle: idle + 1)
        else raise ArgumentError, "unknown detail status #{result.status.inspect}"
        end
      end

      def to_log = to_h

      def to_s
        [
          Ingestion::Report.line("Requests attempted", Ingestion::Report.count(requests)),
          Ingestion::Report.line("Search batches completed", Ingestion::Report.count(batches_completed)),
          Ingestion::Report.line("Batch items requested", Ingestion::Report.count(items_requested)),
          Ingestion::Report.line("Batch items applied", Ingestion::Report.count(items_valid)),
          Ingestion::Report.line("Fallbacks admitted", Ingestion::Report.count(fallbacks_admitted)),
          Ingestion::Report.line("Detail completions", Ingestion::Report.count(details_completed)),
          Ingestion::Report.line("Detail terminal outcomes", Ingestion::Report.count(details_terminal)),
          Ingestion::Report.line("Requests deferred", Ingestion::Report.count(deferred)),
          Ingestion::Report.line("Claims with nothing eligible", Ingestion::Report.count(idle))
        ].join("\n")
      end
    end
  end
end
