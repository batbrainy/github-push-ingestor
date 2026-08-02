module Github
  module Events
    # The malformed-event taxonomy (IMPLEMENTATION_PLAN.md §7).
    #
    # §7 states the reason this is a vocabulary rather than a log message: "'malformed'
    # is a defined predicate, not an exception path ending in a log line." Its table has
    # five rows, three of which quarantine:
    #
    #   Valid non-PushEvent .................. ignored and counted, NOT quarantined
    #   PushEvent missing a required field ... quarantined
    #   Missing type / invalid envelope ...... quarantined
    #   payload.repository_id != repo.id ..... quarantined as an integrity failure
    #   Whole response body is invalid JSON .. request failure, NOT an individual event
    #
    # The codes below are finer-grained than those three rows on purpose — "GitHub did
    # not send head" and "head is not an object name" are different operator stories —
    # and TAXONOMY records which row each one implements, so a spec can assert that the
    # granularity is a refinement of the plan rather than a drift away from it.
    #
    # Two constraints shape everything here, and both come from
    # QuarantinedEvent::OCCURRENCE_MERGE, which deliberately does not refresh error_code
    # on replay:
    #
    #   * The first classification of a payload is permanent. So classification must be
    #     a pure, total, order-stable function of the payload alone.
    #   * A code that means "we could not classify this" would therefore be a permanent
    #     lie about the taxonomy. There is no such code, and an unexpected error on the
    #     write path is counted as events_failed instead (§8, and PushEvent.insert_if_new's
    #     own comment: "reaching this raise means the parser let something through").
    module QuarantineReasons
      # §7's rows, quoted, so the mapping below cites the plan rather than paraphrasing it.
      ROWS = {
        invalid_envelope: "Event missing `type` or with an invalid envelope",
        missing_required_field: "`PushEvent` missing a required field",
        integrity_failure: "`payload.repository_id` != `repo.id`"
      }.freeze

      # The element is not a JSON object at all: null, an array, a string, a number, a
      # boolean. A valid JSON array can contain any of those, and
      # EventSources::Base#events hands them over untouched.
      INVALID_ENVELOPE = "invalid_envelope".freeze

      # `type` absent, blank, or not a String. Not the same as a type we do not process:
      # that is ignored (§7 row 1). This is an envelope we cannot even name, and
      # event_type is a text column that must not receive a non-String.
      MISSING_EVENT_TYPE = "missing_event_type".freeze

      # `id` absent, blank, or neither String nor Integer. github_event_id is the unique
      # key of push_events, so without it the event cannot be persisted or deduplicated.
      MISSING_EVENT_ID = "missing_event_id".freeze

      # `actor` is not an object, or actor.id / actor.login is missing or unusable. Both
      # are load-bearing: push_events.github_actor_id is NOT NULL and a foreign key, and
      # GithubActor validates login.
      INVALID_ACTOR_REFERENCE = "invalid_actor_reference".freeze

      # `repo` is not an object, or repo.id / repo.name is missing or unusable.
      # GithubRepository validates full_name, which is where repo.name maps.
      INVALID_REPOSITORY_REFERENCE = "invalid_repository_reference".freeze

      # `created_at` absent, blank, or not parseable as ISO 8601. push_events.occurred_at
      # is NOT NULL and preserves the event's upstream time.
      INVALID_OCCURRED_AT = "invalid_occurred_at".freeze

      # `payload` is not an object, or one of §7's five documented required fields —
      # repository_id, push_id, ref, head, before — is absent or null. GitHub did not
      # send it.
      MISSING_REQUIRED_FIELD = "missing_required_field".freeze

      # Present but unusable: head or before failing PushEvent::SHA_FORMAT, a
      # non-Integer identifier, a blank or non-String ref. Distinct from
      # MISSING_REQUIRED_FIELD because the remedies differ — one is a GitHub payload
      # change, the other is a value this application refuses.
      INVALID_FIELD_FORMAT = "invalid_field_format".freeze

      # §7's integrity row: the envelope and the payload disagree about which repository
      # the push belongs to, so neither can be trusted as the foreign key.
      REPOSITORY_ID_MISMATCH = "repository_id_mismatch".freeze

      # An identifier outside signed 64-bit. §7's table has no row for value ranges; this
      # is read as a refinement of "present but unusable", and it cannot be dropped:
      # the four identifier columns are bigint, nothing validates numericality, and an
      # over-range value would otherwise reach PostgreSQL and become an unclassified
      # events_failed instead of a quarantined event.
      IDENTIFIER_OUT_OF_RANGE = "identifier_out_of_range".freeze

      # Which §7 row each code implements. Exhaustive by construction: CODES is derived
      # from it, so a new code cannot be added without naming its row.
      TAXONOMY = {
        INVALID_ENVELOPE => :invalid_envelope,
        MISSING_EVENT_TYPE => :invalid_envelope,
        MISSING_EVENT_ID => :invalid_envelope,
        INVALID_ACTOR_REFERENCE => :invalid_envelope,
        INVALID_REPOSITORY_REFERENCE => :invalid_envelope,
        INVALID_OCCURRED_AT => :invalid_envelope,
        MISSING_REQUIRED_FIELD => :missing_required_field,
        INVALID_FIELD_FORMAT => :missing_required_field,
        IDENTIFIER_OUT_OF_RANGE => :missing_required_field,
        REPOSITORY_ID_MISMATCH => :integrity_failure
      }.freeze

      # Which code wins when an envelope is broken in several ways, most to least
      # fundamental: structure, then envelope identity, then payload presence, then
      # payload shape, then cross-field integrity, then range.
      #
      # This is declarative rather than a side effect of the order the processor happens
      # to run its checks in, because the winning code is written to the database once
      # and never revised. Two boundaries carry the weight:
      #
      #   * Envelope identity before payload. The quarantine row is indexed by
      #     github_event_id and carries event_type; both come from the envelope. And an
      #     integrity comparison against an untrustworthy repo.id is meaningless.
      #   * Shape before integrity. With payload.repository_id == "1296269" (a String)
      #     and repo.id == 1296269, Ruby's != is true — so integrity-first would report a
      #     mismatch that does not exist, while shape-first names the actual defect.
      PRECEDENCE = [
        INVALID_ENVELOPE,
        MISSING_EVENT_TYPE,
        MISSING_EVENT_ID,
        INVALID_ACTOR_REFERENCE,
        INVALID_REPOSITORY_REFERENCE,
        INVALID_OCCURRED_AT,
        MISSING_REQUIRED_FIELD,
        INVALID_FIELD_FORMAT,
        REPOSITORY_ID_MISMATCH,
        IDENTIFIER_OUT_OF_RANGE
      ].freeze

      CODES = TAXONOMY.keys.freeze

      module_function

      # @param codes [Array<String>] every code an envelope violated
      # @return [String, nil] the one written to error_code
      def primary(codes)
        codes.min_by { |code| precedence_of(code) }
      end

      def precedence_of(code)
        PRECEDENCE.index(code) ||
          raise(ArgumentError, "#{code.inspect} is not a member of the quarantine taxonomy")
      end

      def row(code)
        TAXONOMY.fetch(code)
      end
    end
  end
end
