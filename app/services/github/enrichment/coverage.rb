module Github
  module Enrichment
    # IMPLEMENTATION_PLAN.md §11's three enrichment coverage percentages, computed over
    # ENRICHMENT_COVERAGE_WINDOW_SECONDS.
    #
    # The piece Github::Enrichment::Summary names and defers — "deliberately not the
    # percentages, which need ENRICHMENT_COVERAGE_WINDOW_SECONDS and a join against
    # push_events". Both arrive with PR 10, and this is where they land.
    #
    # **It never initiates a GitHub request**, structurally and for the reason
    # Github::Ingestion::StateSummary gives: no executor, no transport, no ledger. It does
    # not read github_api_budget at all — one SELECT, and nothing that writes.
    #
    # ## The window is measured on created_at, not occurred_at
    #
    # Coverage grades *this application's* enrichment pipeline, and that pipeline runs on
    # this application's clock throughout: eligibility is
    # COALESCE(last_seen_at, created_at) > floor (Github::Enrichment::CandidateSelector),
    # staleness is fetched_at + TTL, and the budget refills on a wall-clock rate-limit
    # window. A denominator defined by GitHub's event clock would mix two clocks inside one
    # ratio. §11's own wording — "distinct **persisted** push events in the coverage
    # window" — reads the same way, and after downtime created_at is the basis that answers
    # the question an operator is actually asking.
    #
    # It also keeps the offline reviewer path honest. §12 makes the fixture corpus the
    # deterministic path and §16 makes these percentages an Operability gate, but the
    # corpus pins its envelope timestamps to a fixed date — so an occurred_at basis reports
    # three nulls to anyone running the walkthrough after that date, on a database that
    # demonstrably holds enriched events.
    #
    # Rejected alternative, recorded because it is a real one: occurred_at is the indexed
    # column (index_push_events_on_occurred_at) and reads as "GitHub activity in the last N
    # seconds". The cost of not using it is a sequential scan, accepted deliberately — at
    # the pinned defaults the feed yields on the order of 3,000 rows a day, so a month is
    # under 100k rows, and spec/db/schema_spec.rb already states this repository's posture
    # on raw_payload: no index until a query demands one. Note also that created_at is
    # always >= occurred_at, so the occurred_at window is a strict *subset* of this one —
    # the rows it drops are exactly the high-latency catch-up events, and removing them
    # from the denominator alone would inflate the reported percentage.
    #
    # The basis is published in #payload rather than left implicit, so the choice is
    # reviewable from the response instead of only from this comment.
    class Coverage < Data.define(:window_seconds, :window_start, :event_count,
                                 :actor_count, :complete_actor_count,
                                 :repository_count, :complete_repository_count,
                                 :both_complete_event_count)
      # One of Enrichable::ENRICHMENT_STATUSES, interpolated rather than bound: it is a code
      # constant that a CHECK constraint enforces and that db/schema.rb already inlines into
      # two partial-index predicates, so there is no caller input here to bind. A spec pins
      # it against the enum, so a renamed status cannot leave this filtering on a value that
      # no longer exists.
      COMPLETE = "complete".freeze

      ACTOR_COMPLETE = "github_actors.enrichment_status = '#{COMPLETE}'".freeze
      REPOSITORY_COMPLETE = "github_repositories.enrichment_status = '#{COMPLETE}'".freeze

      # `>` rather than `>=`, matching CandidateSelector's eligibility floor — one window
      # convention in this codebase, not two. The table qualifier is mandatory rather than
      # tidy: all three joined tables carry created_at, so an unqualified column is
      # ambiguous and PostgreSQL rejects the statement.
      #
      # No upper bound. A future-dated row is clock skew, and excluding it would remove the
      # same row from the numerator and the denominator together — the eligibility window
      # has none either, for the same reason.
      WINDOW_CLAUSE = "push_events.created_at > :floor".freeze

      # §11's three formulas, as six counts taken in one pass.
      #
      # COUNT(DISTINCT …) is what keeps the entity ratios honest: an actor referenced by two
      # hundred events in the window is one actor on *both* sides of its own ratio, while
      # the event ratio counts rows. The event denominator needs no DISTINCT of its own —
      # the unique index on github_event_id plus PushEvent.insert_if_new's ON CONFLICT DO
      # NOTHING mean a re-polled window never produces a second row for one event.
      #
      # FILTER rather than SUM(CASE …) because it is the same plan and states the intent.
      COUNTS = {
        event_count: "COUNT(*)",
        actor_count: "COUNT(DISTINCT push_events.github_actor_id)",
        complete_actor_count:
          "COUNT(DISTINCT push_events.github_actor_id) FILTER (WHERE #{ACTOR_COMPLETE})",
        repository_count: "COUNT(DISTINCT push_events.github_repository_id)",
        complete_repository_count:
          "COUNT(DISTINCT push_events.github_repository_id) FILTER (WHERE #{REPOSITORY_COMPLETE})",
        both_complete_event_count:
          "COUNT(*) FILTER (WHERE #{ACTOR_COMPLETE} AND #{REPOSITORY_COMPLETE})"
      }.freeze

      # Two decimals. §10 sizes the honest steady state at a low single-digit percentage, so
      # the second decimal is the one that moves; a fourth would read as precision the
      # sampling rate does not have.
      PRECISION = 2

      # The basis, published so a consumer never has to guess which clock bounds the window.
      BASIS = "created_at".freeze

      # joins(:github_actor, :github_repository) rather than hand-written ON clauses, so the
      # join keys come from the associations PushEvent already declares with
      # primary_key: :github_id and a schema change cannot silently desynchronise them.
      #
      # INNER is correct rather than merely convenient: both foreign key columns are NOT
      # NULL and both carry real foreign keys to a UNIQUE github_id, so each join matches
      # exactly one row. It can neither drop a push event from the denominator nor duplicate
      # one into it — which is the property that lets all six counts share one pass and
      # still agree with six separate queries.
      def self.capture(now: Time.current, configuration: Github.configuration)
        window_seconds = configuration.enrichment_coverage_window_seconds
        window_start = now - window_seconds

        values = PushEvent.joins(:github_actor, :github_repository)
                          .where(WINDOW_CLAUSE, floor: window_start)
                          .pick(*COUNTS.each_value.map { |expression| Arel.sql(expression) })

        new(window_seconds: window_seconds, window_start: window_start,
            **COUNTS.keys.zip(Array(values).map(&:to_i)).to_h)
      end

      def actor_coverage_pct = percentage(complete_actor_count, actor_count)
      def repository_coverage_pct = percentage(complete_repository_count, repository_count)

      def events_with_both_entities_enriched_pct
        percentage(both_complete_event_count, event_count)
      end

      # Every count and every denominator, not only the three percentages. A ratio whose
      # denominator is hidden cannot be checked, and "100.0% actor coverage" printed alone
      # over a single actor is exactly the misleading guarantee §16 forbids.
      def payload
        { window_seconds: window_seconds,
          window_start: Ingestion::Report.timestamp(window_start),
          basis: BASIS,
          event_count: event_count,
          actor_count: actor_count,
          complete_actor_count: complete_actor_count,
          actor_coverage_pct: actor_coverage_pct,
          repository_count: repository_count,
          complete_repository_count: complete_repository_count,
          repository_coverage_pct: repository_coverage_pct,
          both_complete_event_count: both_complete_event_count,
          events_with_both_entities_enriched_pct: events_with_both_entities_enriched_pct }
      end

      def to_log
        { coverage_window_seconds: window_seconds, coverage_event_count: event_count,
          actor_coverage_pct: actor_coverage_pct,
          repository_coverage_pct: repository_coverage_pct,
          events_with_both_entities_enriched_pct: events_with_both_entities_enriched_pct }
      end

      private

      # nil, never 0.0. An empty window has no coverage percentage — the ratio is undefined
      # rather than zero — and 0.0 there reads as "nothing is enriched" when the truth is
      # "there is nothing in the window to enrich". §16 forbids exactly that fabricated
      # zero, and #payload publishes the denominator beside every ratio, so nil is
      # self-explanatory rather than a gap.
      def percentage(numerator, denominator)
        return nil if denominator.zero?

        (100.0 * numerator / denominator).round(PRECISION)
      end
    end
  end
end
