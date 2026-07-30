module Github
  module Ingestion
    # One fetched page turned into rows (IMPLEMENTATION_PLAN.md §8 steps 4–9).
    #
    # Its constructor takes a registry and a clock, and deliberately no executor and no
    # event source, so a live GitHub request cannot physically be issued from inside its
    # transaction. That is the same structural technique PR 4 used when it never handed
    # RequestExecutor an event_source_id (Appendix D item 1);
    # Github::BudgetLedger#assert_committable! and Github::LockOrder are the enforced
    # halves. The registry is safe to hold because it is pure — no clock, no database, no
    # network — and interpretation has to live inside the same per-envelope boundary as the
    # write, for the reason three paragraphs down.
    #
    # **One transaction per envelope**, not per page. §16 requires that malformed data "does
    # not terminate the batch", and in PostgreSQL a failed statement aborts the *entire*
    # enclosing transaction — spec/support/constraint_helpers.rb already documents that
    # hazard in this repository. With a page-wide transaction, one unexpected error on
    # envelope five of eight would discard envelopes one to four that the log had already
    # reported as persisted, along with the quarantine rows written for the others. §8 asks
    # for the same shape from the other direction: its durability boundary is per event ("an
    # event is accepted only after its push_events row is committed") and step 9 calls the
    # transaction "short-lived — the advisory lock, not the transaction, spans the HTTP
    # work". It is also what makes a page loop possible at all: no transaction is ever open
    # across a fetch, so a
    # Link-driven page loop needs no change here.
    #
    # What that gives up is page-level atomicity, and nothing needs it — github_event_id
    # uniqueness makes re-processing a partially written page a no-op, which is exactly why
    # §9 requires every fetched page to be processed in full with no known-event stop.
    #
    # **Interpretation is inside the boundary too**, which is not obvious. Classification is
    # pure but not infallible: an envelope carrying a value JSON cannot represent has no
    # fingerprint, so Github::Events::PayloadFingerprint raises rather than invent one. If
    # the page were interpreted in one pass and written in another, that single envelope
    # would take the whole page down — the exact failure §16 forbids.
    class PageWriter
      # Errors where continuing would produce a dishonest run. A locking or transaction
      # invariant is a programming error whose own doc comment asks it to be loud, and a
      # dead connection is not a property of any one envelope — reporting
      # "events_failed: 100, status: completed" would be a lie.
      FATAL_ERRORS = [
        Errors::NestedTransaction, Errors::LockOrderViolation, Errors::ReentrantLock,
        Errors::LockSessionChanged,
        ActiveRecord::ConnectionNotEstablished, ActiveRecord::ConnectionFailed
      ].freeze

      def initialize(registry: Events::ProcessorRegistry.default, clock: -> { Time.current })
        @registry = registry
        @clock = clock
      end

      # @param envelopes [Enumerable<Object>] decoded array elements exactly as
      #   Github::EventSources::Base#events returned them, nils included
      # @param tally [Github::Ingestion::Tally] the page's counters so far
      # @return [Github::Ingestion::Tally]
      def write(envelopes, run_id:, tally: Tally.empty)
        # One instant for the whole page. Within a page that makes IDENTITY_MERGE's >=
        # comparison resolve ties in page order; §7's freshness guard exists to protect
        # against *cross-poll* staleness (the documented 30s–6h event latency), not against
        # intra-page ordering, and sorting the page by occurred_at would desynchronize the
        # DEBUG log from the page a reviewer is reading.
        received_at = @clock.call

        envelopes.reduce(tally) do |accumulated, envelope|
          result = handle(envelope, run_id: run_id, received_at: received_at)
          accumulated.record(result: result, push_type: push_type?(envelope))
        end
      end

      private

      # Exactly one terminal result per envelope, so the counter identities hold and one
      # shape can never be counted twice.
      def handle(envelope, run_id:, received_at:)
        outcome = @registry.process(envelope)

        case outcome.kind
        when :push_event then persist(outcome, run_id: run_id, received_at: received_at)
        when :quarantined then quarantine(outcome, run_id: run_id, received_at: received_at)
        when :ignored then ignore(outcome, run_id: run_id)
        end
      rescue *FATAL_ERRORS
        raise
      rescue StandardError => error
        # Reachable two ways today, both verified rather than assumed: a String carrying a
        # NUL byte (ArgumentError from the PostgreSQL driver for a text column,
        # PG::UntranslatableCharacter for one inside jsonb), and a non-finite Float on the
        # quarantine path, which has no fingerprint. It is also the safety net for
        # PushEvent.insert_if_new's validate!, whose own comment says reaching it "means the
        # parser let something through": that is a defect to fix, not a payload to classify,
        # and a quarantine row carrying an unclassified error_code would be a permanent lie
        # because OCCURRENCE_MERGE never refreshes it. RecordInvalid#message already names
        # every failed validation.
        Rails.logger.error(event: "ingestion.event_failed", run_id: run_id,
                           github_event_id: Events::Envelope.event_id(envelope),
                           error_class: error.class.name, error_message: error.message)
        :failed
      end

      # Feeds ingestion_runs.push_events_seen, which counts envelopes GitHub *typed* as
      # pushes whether or not they normalized (§8 step 4, "Filter PushEvent entries"). Read
      # from the envelope rather than from the outcome, so the number is the same whether the
      # envelope persisted, duplicated, quarantined or failed — page 1's eight envelopes give
      # six either way.
      def push_type?(envelope)
        Events::Envelope.event_type(envelope) == Events::PushEventProcessor::EVENT_TYPE
      end

      # §8 steps 6–8, in one transaction. The stubs come first because push_events' foreign
      # keys point at github_id and a statement sees its own transaction's uncommitted rows;
      # actor before repository always, so two concurrent pages touching the same pair
      # cannot deadlock on the two entity rows.
      def persist(outcome, run_id:, received_at:)
        created_id = ActiveRecord::Base.transaction do
          GithubActor.upsert_stub!(**outcome.actor_attributes, now: received_at)
          GithubRepository.upsert_stub!(**outcome.repository_attributes, now: received_at)

          id = PushEvent.insert_if_new(outcome.push_event_attributes)

          # §7 merge rule 3 and Appendix D item 5: activity updates happen **only** when
          # RETURNING produced a row. On a duplicate the transaction still commits, carrying
          # rule 1's identity refresh and nothing else, so rule 4 — "a duplicate event
          # replay can never reactivate enrichment" — holds structurally rather than by a
          # later check. PR 7 adds the skipped_budget reactivation transition at this one
          # call site; PR 5 owns the gate.
          next nil if id.nil?

          touch_activity(outcome, received_at: received_at)
          id
        end

        # Logged after the commit, so a "persisted" line never precedes durability.
        log_persisted(outcome, run_id: run_id, created_id: created_id)
      end

      def touch_activity(outcome, received_at:)
        GithubActor.touch_activity!(
          github_id: outcome.actor_attributes.fetch(:github_id),
          seen_at: received_at, event_occurred_at: outcome.occurred_at
        )
        GithubRepository.touch_activity!(
          github_id: outcome.repository_attributes.fetch(:github_id),
          seen_at: received_at, event_occurred_at: outcome.occurred_at
        )
      end

      def log_persisted(outcome, run_id:, created_id:)
        if created_id.nil?
          Rails.logger.debug(event: "ingestion.event_duplicate", run_id: run_id, **outcome.to_log)
          return :duplicate
        end

        Rails.logger.debug(
          event: "ingestion.event_persisted", run_id: run_id, **outcome.to_log,
          push_event_id: created_id,
          github_actor_id: outcome.actor_attributes.fetch(:github_id),
          github_repository_id: outcome.repository_attributes.fetch(:github_id),
          occurred_at: outcome.occurred_at.utc.iso8601
        )
        :created
      end

      # One statement, deliberately outside any transaction: a quarantine record must not be
      # discardable by a later failure, and the classification was computed before any write
      # so there is nothing to make atomic with it.
      #
      # INFO rather than DEBUG. §11 puts per-event lines at DEBUG, but the issue requires
      # GitHub event IDs in the logs and §16 requires malformed data to be visibly
      # quarantined — an operator should not have to change log levels to learn that events
      # are being rejected.
      def quarantine(outcome, run_id:, received_at:)
        QuarantinedEvent.record!(
          payload_fingerprint: outcome.payload_fingerprint,
          raw_payload: outcome.raw_payload,
          github_event_id: outcome.github_event_id,
          event_type: outcome.event_type,
          error_code: outcome.error_code,
          error_message: outcome.error_message,
          received_at: received_at
        )

        Rails.logger.info(event: "ingestion.event_quarantined", run_id: run_id, **outcome.to_log)
        :quarantined
      end

      # §7 row 1: "Valid non-PushEvent — Ignored and counted, not quarantined." No rows, no
      # transaction, no stub entities — the counter is the whole record.
      def ignore(outcome, run_id:)
        Rails.logger.debug(event: "ingestion.event_ignored", run_id: run_id, **outcome.to_log)
        :ignored
      end
    end
  end
end
