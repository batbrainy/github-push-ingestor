module Github
  module Enrichment
    # §10's two candidate pools and the predicate borrowing asks about.
    #
    # Deliberately holds no executor and no transport — the technique
    # Github::Ingestion::PageWriter uses — so a GitHub request cannot be issued from a
    # selection query, and every method here is a read.
    #
    # **Two pools, not one status.** Never-enriched candidates remain durable pending work,
    # while staleness is a derived predicate over complete rows. Collapsing stale rows
    # into pending would erase the distinction that keeps first-time enrichment ahead of
    # refresh traffic. A stale-but-enriched entity therefore keeps reading `complete` —
    # which is true, because its payload is still present.
    #
    # Two further consequences of that reading, both intended: a background writer that
    # mutated rows purely because time passed is the shape this codebase refuses
    # everywhere (Github::Ingestion::PollState, Github::BudgetLedger#log_block_cleared),
    # and index_*_on_enrichment_candidates keeps its PR 3 predicate instead of silently
    # absorbing every refresh row.
    class CandidateSelector
      POOLS = %i[ pending refresh ].freeze

      # Durable FIFO. created_at is the instant the entity entered the backlog; unlike
      # last_seen_at it is immutable when later events reference the same entity. The id
      # tie-break makes candidates created in the same timestamp deterministic.
      PENDING_ORDER = "created_at ASC, id ASC".freeze

      # Oldest-fetched first, which is the rule that terminates: a monotone refresh queue
      # cannot starve a complete row behind a hotter neighbour. The first-time backlog
      # has its own FIFO key, so the refresh pool needs its own ordering rule.
      REFRESH_ORDER = "fetched_at ASC, id ASC".freeze

      # When a complete row next becomes refreshable. See #earliest_refresh_at.
      REFRESH_DUE_AT = "GREATEST(fetched_at + make_interval(secs => ?), next_retry_at)".freeze

      def initialize(configuration: Github.configuration)
        @configuration = configuration
      end

      attr_reader :configuration

      # @param entity_type [Github::Enrichment::EntityType]
      # @param pool [Symbol] :pending or :refresh
      # @return [ActiveRecord::Relation]
      def scope(entity_type, pool:, now:)
        case pool
        when :pending then pending_scope(entity_type, now: now)
        when :refresh then refresh_scope(entity_type, now: now)
        else raise ArgumentError, "unknown pool #{pool.inspect}"
        end
      end

      # Whether this class has first-time backlog work that can be claimed now. Fairness
      # uses this narrower predicate for borrowing: a class in backoff need not leave the
      # other class's reserved attempts idle. Refresh suppression uses #pending_backlog?
      # instead, because it asks whether first-time work exists at all.
      def pending_available?(entity_type, now:)
        pending_scope(entity_type, now: now).exists?
      end

      # Backlog presence is deliberately broader than current claimability. A row in
      # backoff or carrying an in-flight lease still represents first-time enrichment
      # work, so refresh traffic must not consume the quota reserved for that backlog.
      def pending_backlog?(entity_type)
        entity_type.model.where(enrichment_status: Enrichable::CANDIDATE_STATUSES).exists?
      end

      # Whether either pool could hand out work for this class right now. Asked before any
      # "when next?" question, because the two are different questions and deriving one
      # from the other is what makes a report say "due now" while the command it sits next
      # to says there is nothing to enrich.
      def claimable?(entity_type, now:)
        return true if pending_available?(entity_type, now: now)
        return false if EntityType.all.any? { |type| pending_backlog?(type) }

        refresh_available?(entity_type, now: now)
      end

      def refresh_available?(entity_type, now:)
        scope(entity_type, pool: :refresh, now: now).exists?
      end

      # The soonest instant at which *either* pool will have work for this class, for a
      # caller that has already established neither has any now.
      # @return [Time, nil] nil when nothing will ever become claimable without new activity
      def earliest_claimable_at(entity_type, now:)
        if EntityType.all.any? { |type| pending_backlog?(type) }
          earliest_pending_at(entity_type, now: now)
        else
          earliest_refresh_at(entity_type, now: now)
        end
      end

      # A pending candidate held back only by its own backoff, lease, or secondary-limit
      # deferral. Pending work has no age cutoff: this instant is a real promise that the
      # row returns to the actionable backlog.
      # @return [Time, nil]
      def earliest_pending_at(entity_type, now:)
        entity_type.model
                   .where(enrichment_status: Enrichable::CANDIDATE_STATUSES)
                   .where.not(next_retry_at: nil)
                   .where(next_retry_at: now..)
                   .minimum(:next_retry_at)
      end

      # When the freshness cache next lets go. A complete row's next legal fetch is the
      # later of its TTL expiry and any retry instant a failed refresh left behind — so
      # GREATEST, not the minimum of two independent columns, and the minimum is taken over
      # that expression rather than over fetched_at alone: the oldest document may be the
      # one carrying the longest backoff.
      #
      # GREATEST ignores NULL in PostgreSQL, which is the behaviour rather than the hazard
      # here — a complete row with no retry instant is due at its TTL expiry, full stop.
      # A NULL fetched_at is excluded for the same reason #refresh_scope excludes it: the
      # refresh predicate could never match such a row, so it has no next refresh to name.
      # @return [Time, nil]
      def earliest_refresh_at(entity_type, now:)
        expression = ActiveRecord::Base.sanitize_sql_array(
          [ REFRESH_DUE_AT, entity_type.refresh_ttl_seconds(configuration) ]
        )

        entity_type.model.complete.where.not(fetched_at: nil).minimum(Arel.sql(expression))
      end

      def stale_before(entity_type, now)
        now - entity_type.refresh_ttl_seconds(configuration)
      end

      private

      def pending_scope(entity_type, now:)
        due(entity_type.model.where(enrichment_status: Enrichable::CANDIDATE_STATUSES), now)
          .order(Arel.sql(PENDING_ORDER))
      end

      def refresh_scope(entity_type, now:)
        due(entity_type.model.complete, now)
          .where(fetched_at: ..stale_before(entity_type, now))
          .order(Arel.sql(REFRESH_ORDER))
      end

      # One predicate, spelled once. next_retry_at means "may not be attempted before T"
      # everywhere in this state machine — a failure backoff, a secondary-limit deferral,
      # and Github::Enrichment::Claim's in-flight lease all write it — so this single
      # clause excludes all three from both claimable pools.
      def due(relation, now)
        relation.where("next_retry_at IS NULL OR next_retry_at <= :now", now: now)
      end
    end
  end
end
