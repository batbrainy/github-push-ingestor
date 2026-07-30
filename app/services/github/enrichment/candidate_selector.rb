module Github
  module Enrichment
    # §10's two candidate pools and the predicate borrowing asks about.
    #
    # Deliberately holds no executor and no transport — the technique
    # Github::Ingestion::PageWriter uses — so a GitHub request cannot be issued from a
    # selection query, and every method here is a read.
    #
    # **Two pools, not one status.** §7 line 572 says an entity "returns to pending when
    # missing, explicitly stale, or reactivated after a budget skip", and §10 line 816
    # says never-enriched pending candidates "always precede TTL-stale refreshes". Those
    # are only compatible if staleness is a *derived predicate over complete rows* rather
    # than a stored transition: collapsing stale rows into pending would erase the very
    # distinction the priority rule is stated over. So the only stored path back to
    # pending is reactivation (Enrichable#touch_activity!), and a stale-but-enriched
    # entity keeps reading `complete` — which is true, the payload is there.
    #
    # Two further consequences of that reading, both intended: a background writer that
    # mutated rows purely because time passed is the shape this codebase refuses
    # everywhere (Github::Ingestion::PollState, Github::BudgetLedger#log_block_cleared),
    # and index_*_on_enrichment_candidates keeps its PR 3 predicate instead of silently
    # absorbing every refresh row.
    class CandidateSelector
      POOLS = %i[ pending refresh ].freeze

      # §10: "Among pending candidates the service enriches newest-first (last_seen_at)."
      #
      # The id tie-break is mandatory rather than cosmetic. PageWriter stamps one
      # received_at for a whole page, so every entity on one page shares an identical
      # last_seen_at, and without a second key the order is plan-dependent and the specs
      # are non-deterministic.
      #
      # NULLS LAST puts a stub that has never been referenced by a distinct persisted
      # event behind every candidate that has been. See #eligibility_floor for why the
      # ordering key is strictly last_seen_at while the *bound* coalesces.
      PENDING_ORDER = "last_seen_at DESC NULLS LAST, id DESC".freeze

      # Oldest-fetched first, which is the rule that terminates: a monotone queue cannot
      # starve a complete row behind a hotter neighbour. §10's newest-first is scoped by
      # its own words to "Among pending candidates", so the refresh pool needs its own.
      REFRESH_ORDER = "fetched_at ASC, id ASC".freeze

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

      # The question §10's borrowing rule asks: "the other class has no CURRENTLY
      # ELIGIBLE candidate (not merely no rows)."
      #
      # Over the pending pool only. §10's prioritization ladder ranks refreshing stale
      # enrichment (3) below enriching never-seen entities (2) *globally*. If this counted
      # refresh candidates, one class would decline to borrow the other's idle capacity
      # because that other class had a stale refresh waiting — letting a refresh outrank a
      # never-enriched candidate and inverting the ladder. The accepted consequence is
      # that a class may spend its own guaranteed share on a refresh while the other class
      # still has a pending backlog, which is exactly what a guarantee means.
      def pending_available?(entity_type, now:)
        pending_scope(entity_type, now: now).exists?
      end

      # The one component this half contributes to §9's effective_enrichment_time: when
      # nothing is due, the soonest instant at which something will be.
      # @return [Time, nil]
      def earliest_retry_at(entity_type, now:)
        entity_type.model
                   .where(enrichment_status: Enrichable::CANDIDATE_STATUSES)
                   .where.not(next_retry_at: nil)
                   .where(next_retry_at: now..)
                   .where(eligible_since_clause, floor: eligibility_floor(now))
                   .minimum(:next_retry_at)
      end

      # Candidates whose activity has aged past §10's eligibility window and are therefore
      # Github::Enrichment::AgeOut's business. Shares every clause with #pending_scope
      # except the direction of the window comparison, which is what makes the two
      # exhaustive: a due candidate is in exactly one of them.
      def expired_scope(entity_type, now:)
        due(entity_type.model.where(enrichment_status: Enrichable::CANDIDATE_STATUSES), now)
          .where("COALESCE(last_seen_at, created_at) <= :floor", floor: eligibility_floor(now))
      end

      def eligibility_floor(now)
        now - configuration.enrichment_eligibility_window_seconds
      end

      def stale_before(entity_type, now)
        now - entity_type.refresh_ttl_seconds(configuration)
      end

      private

      # §10's eligibility window, over COALESCE(last_seen_at, created_at) while
      # PENDING_ORDER sorts on last_seen_at alone. The asymmetry is the whole trick and it
      # is not arbitrary:
      #
      #   * In the *bound*, created_at is safe — it can only ever shorten a row's life,
      #     never promote it — and it is what makes the predicate total. A stub can be
      #     created with a NULL last_seen_at (PageWriter upserts the stub, insert_if_new
      #     returns nil on a duplicate, and the transaction still commits), and
      #     `NULL > floor` is NULL, so without the coalesce such a row would be neither
      #     eligible nor ageable and would sit pending forever — violating B8.
      #   * In the *order*, created_at is unsafe. It means "we saw an envelope", which a
      #     duplicate replay also produces, while §10 pins the ordering key by name to
      #     last_seen_at — the only column that means proven distinct activity. Sorting on
      #     the coalesce would let a replay-created stub outrank a genuinely hot entity.
      #
      # created_at is NOT NULL on both tables and appears in no IDENTITY_MERGE SET list,
      # so it is immutable after the first observation.
      def pending_scope(entity_type, now:)
        due(entity_type.model.where(enrichment_status: Enrichable::CANDIDATE_STATUSES), now)
          .where(eligible_since_clause, floor: eligibility_floor(now))
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
      # clause excludes all three from both pools and from the age-out sweep, and the four
      # queries cannot drift apart.
      def due(relation, now)
        relation.where("next_retry_at IS NULL OR next_retry_at <= :now", now: now)
      end

      def eligible_since_clause
        "COALESCE(last_seen_at, created_at) > :floor"
      end
    end
  end
end
