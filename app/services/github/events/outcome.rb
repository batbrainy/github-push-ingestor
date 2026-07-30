module Github
  module Events
    # What one GitHub event envelope turned into, decided before anything is written.
    #
    # This object *is* the transaction boundary. Github::BudgetLedger#assert_committable!
    # forbids a live request from inside an application transaction, so PR 5's shape is
    # fixed: fetch and interpret outside the database, write inside it. An Outcome is the
    # complete description the writer needs, which means the writer performs no
    # interpretation and the processor performs no I/O — and §12's ~30-case taxonomy
    # matrix becomes a database-free unit spec instead of thirty transactions.
    #
    # The three attribute Hashes carry exactly the keyword arguments of the three model
    # writers PR 3 already ships, so the writer body is
    #
    #   GithubActor.upsert_stub!(**outcome.actor_attributes, now: received_at)
    #   PushEvent.insert_if_new(outcome.push_event_attributes)
    #
    # and the models keep sole ownership of their merge rules while this object knows no
    # SQL at all.
    #
    # Subclassing Data.define rather than passing it a block, matching Github::Request
    # and Github::FetchResult: a constant assigned inside that block would be scoped to
    # the enclosing module, so KINDS would silently become Github::Events::KINDS.
    class Outcome < Data.define(
      :kind, :event_type, :github_event_id, :raw_payload, :occurred_at,
      :push_event_attributes, :actor_attributes, :repository_attributes,
      :error_code, :error_message, :payload_fingerprint
    )
      # §7's taxonomy, as terminal states rather than as a table:
      #
      #   :push_event   normalized and ready to persist
      #   :ignored      a valid event of a type no processor implements — "ignored and
      #                 counted", never quarantined
      #   :quarantined  malformed, classified, and durable
      #
      # There is no :failed kind. A failure is discovered while *writing*, not while
      # interpreting, so it belongs to the writer's result and not to this object.
      KINDS = %i[ push_event ignored quarantined ].freeze

      class << self
        def push_event(event_type:, github_event_id:, raw_payload:, occurred_at:,
                       push_event_attributes:, actor_attributes:, repository_attributes:)
          new(kind: :push_event, event_type: event_type, github_event_id: github_event_id,
              raw_payload: raw_payload, occurred_at: occurred_at,
              push_event_attributes: push_event_attributes,
              actor_attributes: actor_attributes, repository_attributes: repository_attributes)
        end

        def ignored(event_type:, github_event_id:, raw_payload:)
          new(kind: :ignored, event_type: event_type, github_event_id: github_event_id,
              raw_payload: raw_payload)
        end

        def quarantined(event_type:, github_event_id:, raw_payload:,
                        error_code:, error_message:, payload_fingerprint:)
          new(kind: :quarantined, event_type: event_type, github_event_id: github_event_id,
              raw_payload: raw_payload, error_code: error_code, error_message: error_message,
              payload_fingerprint: payload_fingerprint)
        end
      end

      # Every member defaults to nil so the three constructors above can each name only
      # the fields their kind actually carries. kind is validated at construction for the
      # same reason Github::Request validates request_class there: a typo becomes a
      # missing counter and a silently dropped event otherwise.
      def initialize(kind:, event_type: nil, github_event_id: nil, raw_payload: nil,
                     occurred_at: nil, push_event_attributes: nil, actor_attributes: nil,
                     repository_attributes: nil, error_code: nil, error_message: nil,
                     payload_fingerprint: nil)
        raise ArgumentError, "kind must be one of #{KINDS.inspect}, got #{kind.inspect}" unless KINDS.include?(kind)

        super
      end

      def push_event? = kind == :push_event
      def ignored? = kind == :ignored
      def quarantined? = kind == :quarantined

      def to_log
        {
          github_event_id: github_event_id, event_type: event_type,
          error_code: error_code, error_message: error_message,
          payload_fingerprint: payload_fingerprint
        }.compact
      end
    end
  end
end
