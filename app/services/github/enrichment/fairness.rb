module Github
  module Enrichment
    # §10's fairness policy, on the *selection* side: which class works next, out of which
    # pool, and whether it may spend past its guarantee.
    #
    # The division of labour mirrors the one between Github::RateLimitPolicy and
    # Github::BudgetLedger. This decides; the ledger enforces. Nothing here can grant
    # capacity — a wrong answer produces a refused reservation, never an overspend —
    # because the ledger re-checks the same arithmetic under its row lock before debiting.
    #
    # §10's prioritization, applied in order:
    #
    #   1. a never-enriched pending candidate in a class still inside its guarantee, with
    #      actor before repository only as a tie-break;
    #   2. the same, borrowing, when the other class has no currently eligible candidate;
    #   3. a TTL-stale refresh, "only when no never-enriched pending candidate is
    #      eligible" — and §10 scopes that condition globally rather than per class, so a
    #      refresh waits behind the *other* class's pending backlog too.
    #
    # The borrow fact is computed here and asserted to the ledger, and it is stale by
    # construction: a poll can persist a new candidate between this query and the debit.
    # The exposure is bounded to one request — Github::EnrichmentRunner enriches at most
    # one entity per invocation — it self-corrects on the next call, and it can never
    # exceed the class cap, which the ledger checks first.
    class Fairness
      # What to do next. `none` carries the reason, so a caller can report *why* nothing
      # happened rather than only that nothing did.
      class Choice < Data.define(:entity_type, :pool, :borrow, :reason)
        REASONS = %w[
          pending borrowed_pending refresh
          class_exhausted globally_blocked window_uninitialized no_candidate
        ].freeze

        def self.none(reason:)
          new(reason: reason)
        end

        def initialize(reason:, entity_type: nil, pool: nil, borrow: false)
          raise ArgumentError, "unknown reason #{reason.inspect}" unless REASONS.include?(reason)

          super
        end

        def chosen? = !entity_type.nil?

        def to_log
          { entity_type: entity_type&.key, pool: pool, borrow: (true if borrow),
            choice_reason: reason }.compact
        end
      end

      def initialize(configuration: Github.configuration,
                     selector: CandidateSelector.new(configuration: configuration))
        @configuration = configuration
        @selector = selector
      end

      attr_reader :configuration, :selector

      # @param entity_class [Class, Symbol, nil] restricts the choice to one class; nil
      #   lets §10's fairness pick. PR 8's per-class jobs pass one and the one-shot's
      #   --class flag passes one, and neither bypasses any budget rule by doing so.
      # @return [Choice]
      def choose(entity_class: nil, now: Time.current)
        budget = EnrichmentSchedule.current_budget
        blocked = global_block(budget, now: now)
        return blocked if blocked

        requested = entity_class.nil? ? EntityType.all : [ EntityType.fetch(entity_class) ]
        # Asked once for both classes and then only read: the borrow condition is about
        # the class this cycle did *not* pick, so re-querying per candidate would issue
        # the same statement twice.
        eligible = EntityType.all.index_with { |type| selector.pending_available?(type, now: now) }

        pending_choice(budget, requested, eligible) ||
          refresh_choice(budget, requested, eligible, now: now) ||
          Choice.none(reason: "no_candidate")
      end

      private

      # The conditions that stop *all* enrichment, asked before any entity query so a
      # blocked cycle costs one row read rather than five. :share_exhausted is deliberately
      # not among them: it is a denial about one class rather than a stop, which is the
      # same reason Github::EnrichmentSchedule excludes it.
      def global_block(budget, now:)
        return nil if budget.nil?

        if budget.global_blocked_until.present? && budget.global_blocked_until > now
          Choice.none(reason: "globally_blocked")
        elsif budget.window_initialized_at.nil?
          # §7: enrichment is ineligible until the first real poll initializes the window
          # from authoritative headers. Asked here as well as in the ledger so a fresh
          # install reports the honest reason instead of taking the global request gate to
          # be told the same thing.
          Choice.none(reason: "window_uninitialized")
        elsif budget.enrichment_used >= budget.enrichment_allowance
          Choice.none(reason: "class_exhausted")
        end
      end

      def pending_choice(budget, requested, eligible)
        available = requested.select { |type| eligible.fetch(type) }
        return nil if available.empty?

        within = available.find { |type| room_within_guarantee?(budget, type) }
        return Choice.new(entity_type: within, pool: :pending, borrow: false, reason: "pending") if within

        borrower = available.find { |type| other_classes_quiet?(type, eligible) }
        return nil if borrower.nil?

        Choice.new(entity_type: borrower, pool: :pending, borrow: true, reason: "borrowed_pending")
      end

      # §10: "a refresh spends budget only when no pending candidate is currently
      # eligible". Read over every class, not only the requested one, so --class actor
      # cannot promote an actor refresh above a repository still waiting to be enriched
      # for the first time.
      def refresh_choice(budget, requested, eligible, now:)
        return nil if eligible.values.any?

        type = requested.find do |candidate|
          selector.scope(candidate, pool: :refresh, now: now).exists?
        end
        return nil if type.nil?

        borrow = !room_within_guarantee?(budget, type)
        # With no pending candidate anywhere, "the other class has no currently eligible
        # candidate" is true by definition, so a refresh past the guarantee is a legal
        # borrow rather than a starve.
        Choice.new(entity_type: type, pool: :refresh, borrow: borrow, reason: "refresh")
      end

      # Derived from the *stored* enrichment_allowance, exactly as
      # Github::BudgetLedger#share_cap is, so this predicate and the ledger's guard compute
      # the same number from the same row.
      def room_within_guarantee?(budget, entity_type)
        return true if budget.nil?

        guarantee = Allowances.split(budget.enrichment_allowance, configuration.actor_enrichment_share)
                              .fetch(entity_type.request_class)
        share_used(budget, entity_type) < guarantee
      end

      # §10's borrowing condition, verbatim: the other class has no CURRENTLY ELIGIBLE
      # candidate, not merely no rows.
      def other_classes_quiet?(entity_type, eligible)
        eligible.except(entity_type).values.none?
      end

      def share_used(budget, entity_type)
        entity_type.request_class == :actor ? budget.actor_share_used : budget.repository_share_used
      end
    end
  end
end
