module Github
  # §9's enrichment scheduling rule, as a value:
  #
  #   effective_enrichment_time = max(
  #     entity.next_retry_at,            # entity-scoped backoff, lease, or Retry-After
  #     global_blocked_until,            # truly global blocks only (§10)
  #     enrichment_class_blocked_until   # derived: enrichment_used >= enrichment_allowance ? reset_at : nil
  #   )
  #
  # The sibling of Github::PollSchedule, and a value object under app/services/github/ for
  # the three reasons that file gives: it spans two tables — one component comes from an
  # entity row and two from github_api_budget — so neither model owns it; §12 asks for a
  # unit test of this rule, and that is only a unit test if the rule is constructible from
  # three Times with no database; and it is the shape every pure value here already has.
  #
  # Three components rather than five, and no force:. §9 licenses --force against
  # cadence_due_at and the stored ETag, "nothing else" — and enrichment has no cadence to
  # bypass. All three components below are on §9's explicit not-bypassed list:
  # global_blocked_until and class blocking literally, and next_retry_at is the entity
  # analogue of retry_not_before_at (§10's error-context classification is precisely that
  # split — a source failure defers the source, an entity failure defers the entity).
  #
  # The per-class fairness share is deliberately absent. A share exhaustion is a *denial*,
  # not a deferral: it is relieved either by the window rolling or by the other class
  # running out of currently eligible candidates, and the second has no instant to name.
  # Admitting it here would also make borrowing unreachable, because #due? would answer
  # false before the runner ever got to compute one.
  #
  # nil means due now. Every one of these is nil on a freshly stubbed entity and a clean
  # ledger, so nil is the *ordinary* case, not an edge one.
  class EnrichmentSchedule < Data.define(:next_retry_at, :global_blocked_until,
                                         :enrichment_class_blocked_until)
    # §9's order, which is PollSchedule's convention too: the constraint an operator can
    # act on first comes first. It is the tie-break for #binding_component.
    COMPONENTS = %i[
      next_retry_at global_blocked_until enrichment_class_blocked_until
    ].freeze

    class << self
      # @param entity [GithubActor, GithubRepository] anything including Enrichable
      # @param budget [GithubApiBudget, nil] nil on a clean checkout — nothing seeds the
      #   row, only a reservation creates it, and a missing ledger constrains nothing.
      # @param now [Time] needed because one component is derived, not stored.
      def for(entity:, now:, budget: current_budget)
        new(
          next_retry_at: entity.next_retry_at,
          global_blocked_until: budget&.global_blocked_until,
          enrichment_class_blocked_until: budget&.enrichment_class_blocked_until(now: now)
        )
      end

      # find_by, never bootstrap!: reading a schedule must not create the ledger row.
      # Only a reservation does that, and only inside the request gate.
      def current_budget
        GithubApiBudget.find_by(id: GithubApiBudget::SINGLETON_ID)
      end
    end

    # @return [Hash{Symbol => Time}] the constraints actually in play, nils dropped.
    #   Used for logging and for #binding_component.
    def components
      COMPONENTS.each_with_object({}) do |name, present|
        value = public_send(name)
        present[name] = value unless value.nil?
      end
    end

    # @return [Time, nil] nil means no constraint applies — enrich now.
    def effective_enrichment_time
      components.values.max
    end

    # Which constraint produced the answer. Naming the binding one tells an operator
    # which of three things to change.
    # @return [Symbol, nil]
    def binding_component
      present = components
      return nil if present.empty?

      latest = present.values.max
      COMPONENTS.find { |name| present[name] == latest }
    end

    # <= rather than <, for the reason PollSchedule gives: PostgreSQL truncates a
    # timestamp to microseconds on the way in and Time.current does not, and
    # next_retry_at is a round-tripped column. An entity due at exactly `now` is due.
    def due?(now:)
      effective = effective_enrichment_time

      effective.nil? || effective <= now
    end

    def to_log
      components.transform_values { |value| value.utc.iso8601 }
    end
  end
end
