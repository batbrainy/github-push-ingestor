module Github
  module Enrichment
    # B8: "Bound the enrichment backlog via the eligibility window and skipped_budget
    # state (no unbounded growth)." §10: "candidates that age beyond the eligibility
    # window transition to skipped_budget."
    #
    # This is the **only** writer of skipped_budget, which is what lets
    # Enrichable#touch_activity!'s reactivation CASE be one line: every skipped row came
    # through a WHERE of CANDIDATE_STATUSES, and no row in those two statuses has ever
    # completed, so "skipped_budget implies missing enrichment" is a derived invariant
    # rather than an assumption.
    #
    # Budget exhaustion does not cause a skip. §12's sequence is "exhaustion → deferred →
    # skipped_budget → reactivation only via a genuinely new event": exhaustion produces a
    # deferral that writes no entity state at all, and a row becomes skipped only once its
    # own activity has aged past the window. That is why Github::EnrichmentRunner runs
    # this *before* it asks whether it may spend — skipping has to keep happening while
    # the budget is exhausted, which is precisely when boundedness matters.
    #
    # Holds no executor and no transport.
    class AgeOut
      # An unbounded UPDATE over a table taking on §10's ~2,000 candidates an hour would
      # eventually hold hundreds of thousands of row locks in one statement. Bounded is
      # honest, and the ORDER BY makes the residue always the *least* overdue, so progress
      # is monotone and no particular row can be passed over forever by an unlucky plan.
      BATCH_SIZE = 1_000

      def initialize(configuration: Github.configuration,
                     selector: CandidateSelector.new(configuration: configuration))
        @configuration = configuration
        @selector = selector
      end

      attr_reader :configuration, :selector

      # @return [Hash{Symbol => Integer}] rows skipped per entity type
      def call(now:, entity_types: EntityType.all)
        entity_types.index_with { |entity_type| sweep(entity_type, now: now) }
      end

      private

      def sweep(entity_type, now:)
        skipped = ActiveRecord::Base.connection.exec_update(
          sweep_sql(entity_type, now: now), "Github::Enrichment::AgeOut Sweep"
        )
        log(entity_type, skipped: skipped, now: now)
        skipped
      end

      # enrichment_attempts, last_error and next_retry_at are absent from the SET list on
      # purpose. A skip is not an attempt and knows nothing about failures — and leaving
      # next_retry_at is what makes reactivation's "immediately due" property provable:
      # the WHERE requires it to be NULL or already past, so no skipped_budget row can
      # carry a future instant, and touch_activity! needs no clearing clause.
      #
      # updated_at *is* bumped, unlike Github::Enrichment::Claim's lease, under the same
      # rule stated there: this changes the entity's observable state.
      #
      # The retry-due clause inside the subquery is what stops the sweep skipping an
      # entity another worker is currently enriching — a leased row carries
      # claim_time + lease > now — and FOR UPDATE SKIP LOCKED stops the sweep blocking
      # behind that worker's own statement.
      def sweep_sql(entity_type, now:)
        candidates = selector.expired_scope(entity_type, now: now)
                             .select(:id)
                             .order(Arel.sql("COALESCE(last_seen_at, created_at) ASC"))
                             .limit(BATCH_SIZE)
                             .lock("FOR UPDATE SKIP LOCKED").to_sql

        ActiveRecord::Base.sanitize_sql_array([ <<~SQL.squish, now, now ])
          UPDATE #{entity_type.table_name}
             SET enrichment_status = 'skipped_budget',
                 skipped_at = ?,
                 updated_at = GREATEST(updated_at, ?)
           WHERE id IN (#{candidates})
        SQL
      end

      # §11 puts "enrichment … skipped" at INFO, but one line per row would emit thousands
      # in a single sweep. One summary per class, and nothing at all when the count is
      # zero — the argument Github::BudgetLedger#log_class_exhausted already makes: a line
      # that recurs on every quiet cycle buries the stream §11 deliberately sizes.
      def log(entity_type, skipped:, now:)
        return if skipped.zero?

        Rails.logger.info(event: "enrichment.aged_out", entity_type: entity_type.key,
                          skipped_count: skipped, batch_size: BATCH_SIZE,
                          eligible_since: selector.eligibility_floor(now).utc.iso8601)
      end
    end
  end
end
