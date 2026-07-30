module Github
  # §9's poll scheduling rule, as a value:
  #
  #   effective_poll_time(force:) = max(
  #     force ? nil : cadence_due_at,   # POLL_INTERVAL_SECONDS, default 300
  #     poll_floor_until,               # X-Poll-Interval — GitHub's floor, must be obeyed
  #     retry_not_before_at,            # source-scoped Retry-After / backoff
  #     global_blocked_until,           # truly global blocks only (§10)
  #     poll_class_blocked_until        # derived: poll_used >= poll_allowance ? reset_at : nil
  #   )
  #
  # Five components rather than one collapsed timestamp, because a collapsed one cannot
  # answer the two questions §9 asks of it: --force could not tell which part it may
  # bypass, and a routine X-RateLimit-Reset on a healthy 200 would defer every poll to the
  # top of the hour.
  #
  # A Data object under app/services/github/ rather than a method on EventSource, for
  # three reasons. It spans two tables — three components come from event_sources and two
  # from github_api_budget — so neither model owns it, and EventSource is deliberately
  # free of budget state (a spec asserts it carries no rate-limit columns; reaching for
  # the ledger from inside it would be the same thing in method form). §12 asks for a unit
  # test of this rule, and that is only a unit test if the rule is constructible from five
  # Times with no database. And it is the shape every pure value here already has:
  # Allowances, RateLimitSnapshot, Tally.
  #
  # nil means due now. Every one of these columns is nil on a clean checkout, so nil is
  # the *ordinary* case, not an edge one — which is why #due? and every caller treat it as
  # "no constraint" rather than comparing against it.
  class PollSchedule < Data.define(:cadence_due_at, :poll_floor_until, :retry_not_before_at,
                                   :global_blocked_until, :poll_class_blocked_until)
    # Order is the tie-break for #binding_component, and it is the plan's order: the
    # constraint an operator can act on first comes first.
    COMPONENTS = %i[
      cadence_due_at poll_floor_until retry_not_before_at
      global_blocked_until poll_class_blocked_until
    ].freeze

    # §9: "--force bypasses the application's configured cadence (cadence_due_at) and
    # omits the stored ETag — nothing else." One constant, one place, so the claim is
    # checkable rather than distributed. The ETag half lives in IngestionRunner, which is
    # the only thing holding one.
    FORCEABLE = %i[ cadence_due_at ].freeze

    class << self
      # @param event_source [EventSource]
      # @param budget [GithubApiBudget, nil] nil on a clean checkout — nothing seeds the
      #   row, only a reservation creates it, and a missing ledger constrains nothing.
      # @param now [Time] needed because one component is derived, not stored.
      def for(event_source:, now:, budget: current_budget)
        new(
          cadence_due_at: event_source.cadence_due_at,
          poll_floor_until: event_source.poll_floor_until,
          retry_not_before_at: event_source.retry_not_before_at,
          global_blocked_until: budget&.global_blocked_until,
          poll_class_blocked_until: budget&.poll_class_blocked_until(now: now)
        )
      end

      # find_by, never bootstrap!: reading a schedule must not create the ledger row.
      # Only a reservation does that, and only inside the request gate.
      def current_budget
        GithubApiBudget.find_by(id: GithubApiBudget::SINGLETON_ID)
      end
    end

    # @return [Hash{Symbol => Time}] the constraints actually in play, nils dropped.
    #   Used for logging and for #binding_component; --force removes exactly one key.
    def components(force: false)
      dropped = force ? FORCEABLE : []

      COMPONENTS.each_with_object({}) do |name, present|
        next if dropped.include?(name)

        value = public_send(name)
        present[name] = value unless value.nil?
      end
    end

    # @return [Time, nil] nil means no constraint applies — poll now.
    def effective_poll_time(force: false)
      components(force: force).values.max
    end

    # Which constraint produced the answer. §9's deferral line names *a* reason; naming
    # the binding one tells an operator which of five things to change.
    # @return [Symbol, nil]
    def binding_component(force: false)
      present = components(force: force)
      return nil if present.empty?

      latest = present.values.max
      COMPONENTS.find { |name| present[name] == latest }
    end

    # <= rather than <: PostgreSQL truncates a timestamp to microseconds on the way in
    # and Time.current does not, so a round-tripped instant can compare unequal to the
    # one that produced it. A poll that is due at exactly `now` is due.
    def due?(now:, force: false)
      effective = effective_poll_time(force: force)

      effective.nil? || effective <= now
    end

    def to_log(force: false)
      components(force: force).transform_values { |value| value.utc.iso8601 }
    end
  end
end
