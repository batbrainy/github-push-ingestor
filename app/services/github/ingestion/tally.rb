module Github
  module Ingestion
    # The counters of one ingestion run (IMPLEMENTATION_PLAN.md §7, §11).
    #
    # A separate object because the counter arithmetic is worth asserting on its own, with
    # no database and no fixtures. Two identities hold for every run:
    #
    #   events_received  = push_events_seen + events_ignored + invalid_envelope_quarantines
    #   push_events_seen = events_created + duplicates_skipped + push_quarantines + events_failed
    #
    # Immutable, like every other value object here, so a counter cannot be bumped from
    # two places by accident: #record returns the next Tally rather than mutating this one.
    #
    # events_ignored has no column. §7's ingestion_runs field list does not include one and
    # PR 3 owns the schema, so it is logged and printed but not persisted — and it is
    # honestly *not* reconstructible from the stored counters, because an envelope with no
    # usable type is quarantined rather than ignored, so events_received - push_events_seen
    # counts both. #persistable_attributes and #to_log make that split visible at the call
    # site instead of hiding it.
    class Tally < Data.define(
      :pages_fetched, :events_received, :push_events_seen, :events_created,
      :duplicates_skipped, :events_quarantined, :events_ignored, :events_failed
    )
      # What can happen to one envelope, exhaustively. :failed is the writer's, not the
      # processor's — it means an unexpected error while writing, which is why
      # Github::Events::Outcome has no such kind.
      RESULTS = {
        created: :events_created,
        duplicate: :duplicates_skipped,
        quarantined: :events_quarantined,
        ignored: :events_ignored,
        failed: :events_failed
      }.freeze

      # The seven columns §7 lists on ingestion_runs, in the plan's order.
      PERSISTED = IngestionRun::COUNTERS

      def self.empty
        new(pages_fetched: 0, events_received: 0, push_events_seen: 0, events_created: 0,
            duplicates_skipped: 0, events_quarantined: 0, events_ignored: 0, events_failed: 0)
      end

      # A page that decoded into an array of envelopes and reached the processor. A 304, a
      # deferral, a transport failure and an undecodable body all contribute nothing —
      # the *attempt* is counted by github_api_budget.poll_used and by the DEBUG request
      # line, so nothing is lost, and an undecodable page stays distinguishable from an
      # empty one.
      def record_page(events_received:)
        with(pages_fetched: pages_fetched + 1, events_received: self.events_received + events_received)
      end

      # Exactly one result per envelope, recorded after its transaction commits — counting
      # before would credit events_created to a row a later failure rolled back.
      #
      # push_type is carried separately from result because push_events_seen counts what
      # GitHub *typed* as a push whether or not it normalized (§8 step 4), so a quarantined
      # PushEvent increments both push_events_seen and events_quarantined.
      def record(result:, push_type:)
        counter = RESULTS.fetch(result) { raise ArgumentError, "unknown result #{result.inspect}" }

        updates = { counter => public_send(counter) + 1 }
        updates[:push_events_seen] = push_events_seen + 1 if push_type

        with(**updates)
      end

      def persistable_attributes
        to_h.slice(*PERSISTED)
      end

      def to_log
        to_h
      end

      # §9's end-of-run block. A superset of the plan's five items: ignored and failed are
      # printed too, because "0 failed" is information an operator wants and §11 requires
      # the ignored count to be visible. Budget remaining is deliberately absent — the
      # state summary prints immediately after this and already carries it, and §9 wants
      # one number, not two that could disagree.
      def to_s
        [
          Report.line("Pages fetched", Report.count(pages_fetched)),
          Report.line("Events seen", Report.count(events_received)),
          Report.line("Push events created", Report.count(events_created)),
          Report.line("Duplicates skipped", Report.count(duplicates_skipped)),
          Report.line("Events quarantined", Report.count(events_quarantined)),
          Report.line("Non-push events ignored", Report.count(events_ignored)),
          Report.line("Events failed", Report.count(events_failed))
        ].join("\n")
      end
    end
  end
end
