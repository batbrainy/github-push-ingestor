module Github
  module Enrichment
    # The result of interpreting one enrichment response body — §10's third
    # error-context row: "actor/repo response malformed → entity permanent_failure or
    # retryable_failure per classification."
    #
    # One return type with a kind, rather than an exception per failure, for
    # Github::Ingestion::Report's reason applied to parsing: a caller branches once
    # instead of rescuing three classes and eventually missing one. Parsing is pure — no
    # clock, no database, no network — so §12's mapping matrix is a database-free unit
    # spec, exactly as it is for Github::Events::PushEventProcessor.
    class Document < Data.define(:kind, :attributes, :error_code, :error_message)
      KINDS = %i[ ok malformed identity_mismatch ].freeze

      class << self
        def ok(attributes:)
          new(kind: :ok, attributes: attributes.freeze, error_code: nil, error_message: nil)
        end

        def malformed(error_code:, error_message:)
          new(kind: :malformed, attributes: {}.freeze,
              error_code: error_code, error_message: error_message)
        end

        # A mismatched id is its own kind rather than a flavour of "malformed", because
        # the document is perfectly well formed — it just describes a *different* entity.
        # GitHub logins are recyclable, so a stale actor.url can legitimately resolve to
        # another person, and writing that payload into this row would corrupt the
        # identity join push_events.github_actor_id still relies on. The URL must never be
        # trusted for this row again, and the log should name the real reason.
        def identity_mismatch(expected:, actual:)
          new(kind: :identity_mismatch, attributes: {}.freeze,
              error_code: "identity_mismatch",
              error_message: "document identifies #{actual.inspect}, expected #{expected.inspect}")
        end
      end

      def ok? = kind == :ok

      def to_log
        { document_kind: kind, error_code: error_code }.compact
      end
    end
  end
end
