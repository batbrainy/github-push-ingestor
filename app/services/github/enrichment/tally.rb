module Github
  module Enrichment
    # What one `bin/enrich` invocation did, across however many cycles it ran.
    #
    # Immutable, like Github::Ingestion::Tally: #record returns a new value rather than
    # mutating, so a partially accumulated count can never be observed and a caller cannot
    # hold a stale reference that later changes underneath it.
    class Tally < Data.define(:cycles, :enriched, :failed, :deferred, :idle, :lease_lost,
                              :aged_out)
      # Github::EnrichmentRunner::Result::STATUSES, as counters. Keyed by the same strings
      # so a new status cannot be silently uncounted — #record fetches and raises.
      COUNTERS = {
        "enriched" => :enriched, "failed" => :failed, "deferred" => :deferred,
        "idle" => :idle, "lease_lost" => :lease_lost
      }.freeze

      def self.empty
        new(cycles: 0, enriched: 0, failed: 0, deferred: 0, idle: 0, lease_lost: 0, aged_out: 0)
      end

      # @param result [Github::EnrichmentRunner::Result]
      def record(result)
        counter = COUNTERS.fetch(result.status) { raise ArgumentError, "unknown status #{result.status.inspect}" }

        with(cycles: cycles + 1, aged_out: aged_out + result.aged_out,
             counter => public_send(counter) + 1)
      end

      def to_log = to_h

      def to_s
        [
          Ingestion::Report.line("Enrichment cycles", Ingestion::Report.count(cycles)),
          Ingestion::Report.line("Entities enriched", Ingestion::Report.count(enriched)),
          Ingestion::Report.line("Entities failed", Ingestion::Report.count(failed)),
          Ingestion::Report.line("Cycles deferred", Ingestion::Report.count(deferred)),
          Ingestion::Report.line("Cycles with nothing eligible", Ingestion::Report.count(idle)),
          Ingestion::Report.line("Candidates skipped (budget)", Ingestion::Report.count(aged_out))
        ].join("\n")
      end
    end
  end
end
