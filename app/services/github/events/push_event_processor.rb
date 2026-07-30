module Github
  module Events
    # The tolerant `PushEvent` parser (IMPLEMENTATION_PLAN.md §7, §13; Story 1 child 5).
    #
    # §7: "the currently documented required PushEvent payload fields are repository_id,
    # push_id, ref, head, and before. The parser requires these fields but tolerates
    # additional unknown fields — GitHub can add response fields without a new API
    # version — and the entire event is retained in raw_payload regardless."
    #
    # It is a pure function of one envelope: no clock, no database, no network. That is
    # what makes §12's taxonomy matrix a fast unit spec, and it is also required for
    # correctness — QuarantinedEvent::OCCURRENCE_MERGE never refreshes error_code, so the
    # first classification of a payload is permanent and must not depend on anything
    # outside the payload.
    #
    # The required-field set is wider than §7's five, and deliberately so: it is the
    # **union** of those five and every NOT NULL or validated attribute of the three
    # models the write path touches — push_events (nine columns, all NOT NULL, plus
    # SHA_FORMAT), github_actors (github_id, login), github_repositories (github_id,
    # full_name). Both upsert_stub! methods call validate! precisely so a malformed
    # envelope cannot abort the ingest transaction, so anything they would reject has to
    # be classified here instead. Without the actor.login and repo.name clauses, a real
    # envelope with a null login would land in events_failed rather than in the taxonomy.
    #
    # #call never raises for malformed data — that is the whole point of the taxonomy.
    # The single exception is a payload carrying a value JSON cannot represent (a
    # non-finite Float, which JSON.parse produces from a literal like 1e400): it has no
    # fingerprint, so it has no quarantine row available to it, and its only honest
    # terminal outcome is events_failed via the writer's rescue. Note the asymmetry, which
    # was verified rather than assumed: a *well-formed* envelope carrying such a value is
    # never fingerprinted, and ActiveSupport's JSON encoder writes it into jsonb as null
    # without raising — so it persists, with that one field nulled, inside ADR 0001's
    # semantic-retention tradeoff.
    #
    # Envelope structure and the event type are the registry's half of the taxonomy; by
    # the time this runs, the envelope is a Hash whose type is exactly EVENT_TYPE.
    class PushEventProcessor
      EVENT_TYPE = "PushEvent".freeze

      # §7's five, in the order they are reported, so error_message reads the same way
      # every time.
      REQUIRED_PAYLOAD_FIELDS = %w[ repository_id push_id ref head before ].freeze

      # The four identifier columns are bigint. Nothing in PushEvent or Enrichable
      # validates numericality, so a value outside this range would reach PostgreSQL and
      # become an unclassified failure rather than a quarantined event.
      BIGINT_RANGE = (-(2**63)..(2**63) - 1).freeze

      def self.event_type = EVENT_TYPE

      # @param envelope [Hash] one decoded GitHub event, type already confirmed
      # @return [Github::Events::Outcome] :push_event or :quarantined
      def call(envelope)
        violations = []

        github_event_id = normalize_event_id(envelope, violations)
        actor = normalize_actor(envelope["actor"], violations)
        repository = normalize_repository(envelope["repo"], violations)
        occurred_at = normalize_occurred_at(envelope["created_at"], violations)
        payload = normalize_payload(envelope["payload"], repository, violations)

        return quarantine(envelope, github_event_id, violations) if violations.any?

        Outcome.push_event(
          event_type: EVENT_TYPE,
          github_event_id: github_event_id,
          raw_payload: envelope,
          occurred_at: occurred_at,
          push_event_attributes: {
            github_event_id: github_event_id,
            github_push_id: payload.fetch(:github_push_id),
            github_repository_id: repository.fetch(:github_id),
            github_actor_id: actor.fetch(:github_id),
            ref: payload.fetch(:ref),
            head_sha: payload.fetch(:head_sha),
            before_sha: payload.fetch(:before_sha),
            occurred_at: occurred_at,
            raw_payload: envelope
          },
          actor_attributes: actor,
          repository_attributes: repository
        )
      end

      private

      def quarantine(envelope, github_event_id, violations)
        Outcome.quarantined(
          event_type: EVENT_TYPE,
          github_event_id: github_event_id,
          raw_payload: envelope,
          error_code: QuarantineReasons.primary(violations.map(&:first)),
          error_message: violations.map(&:last).join("; "),
          payload_fingerprint: PayloadFingerprint.fingerprint(envelope)
        )
      end

      # github_event_id is the unique key of push_events, so an envelope without a usable
      # one can be neither persisted nor deduplicated. Envelope.event_id owns the reading
      # rule; this method owns what its absence means.
      def normalize_event_id(envelope, violations)
        github_event_id = Envelope.event_id(envelope)
        return github_event_id if github_event_id

        violations << [ QuarantineReasons::MISSING_EVENT_ID, "id is #{describe(envelope["id"])}" ]
        nil
      end

      # Envelope-to-stub mapping (§7):
      #   actor.login -> login, actor.display_login -> display_login,
      #   actor.url -> api_url, actor.avatar_url -> avatar_url
      # name and raw_payload are enrichment-owned and deliberately absent.
      def normalize_actor(actor, violations)
        unless actor.is_a?(Hash)
          violations << [ QuarantineReasons::INVALID_ACTOR_REFERENCE, "actor is #{describe(actor)}" ]
          return nil
        end

        github_id = identifier(actor["id"], "actor.id", QuarantineReasons::INVALID_ACTOR_REFERENCE, violations)
        login = required_string(actor["login"], "actor.login",
                                QuarantineReasons::INVALID_ACTOR_REFERENCE, violations)
        return nil if github_id.nil? || login.nil?

        {
          github_id: github_id,
          login: login,
          display_login: optional_string(actor["display_login"]),
          api_url: optional_string(actor["url"]),
          avatar_url: optional_string(actor["avatar_url"])
        }
      end

      # Envelope-to-stub mapping (§7): event.repo.name is the qualified owner/repository
      # form and maps to full_name — it is deliberately *not* equated with the enriched
      # short name. name is the final segment, and only when the value is actually
      # qualified: an unqualified string is not a qualified name, and guessing would
      # destroy the very distinction this mapping exists to preserve.
      def normalize_repository(repo, violations)
        unless repo.is_a?(Hash)
          violations << [ QuarantineReasons::INVALID_REPOSITORY_REFERENCE, "repo is #{describe(repo)}" ]
          return nil
        end

        github_id = identifier(repo["id"], "repo.id",
                               QuarantineReasons::INVALID_REPOSITORY_REFERENCE, violations)
        full_name = required_string(repo["name"], "repo.name",
                                    QuarantineReasons::INVALID_REPOSITORY_REFERENCE, violations)
        return nil if github_id.nil? || full_name.nil?

        {
          github_id: github_id,
          full_name: full_name,
          name: full_name.include?("/") ? full_name.split("/").last : nil,
          api_url: optional_string(repo["url"])
        }
      end

      # Time.iso8601, not Time.zone.parse: the latter answers nil for junk, which would
      # travel as far as a NotNullViolation inside the ingest transaction instead of
      # being classified here.
      def normalize_occurred_at(created_at, violations)
        if created_at.is_a?(String) && created_at.present?
          begin
            return Time.iso8601(created_at).utc
          rescue ArgumentError
            # Falls through to the violation below.
          end
        end

        violations << [ QuarantineReasons::INVALID_OCCURRED_AT, "created_at is #{describe(created_at)}" ]
        nil
      end

      def normalize_payload(payload, repository, violations)
        unless payload.is_a?(Hash)
          violations << [ QuarantineReasons::MISSING_REQUIRED_FIELD, "payload is #{describe(payload)}" ]
          return nil
        end

        # Counted rather than checked with #any?, so a payload is judged on its own
        # defects and not on an earlier normalizer's.
        before_count = violations.length

        missing = REQUIRED_PAYLOAD_FIELDS.reject { |field| !payload[field].nil? }
        if missing.any?
          violations << [ QuarantineReasons::MISSING_REQUIRED_FIELD,
                          "payload is missing #{missing.join(", ")}" ]
        end

        repository_id = identifier_field(payload["repository_id"], "payload.repository_id", violations)
        github_push_id = identifier_field(payload["push_id"], "payload.push_id", violations)
        ref = required_ref(payload["ref"], violations)
        head_sha = object_name(payload["head"], "payload.head", violations)
        before_sha = object_name(payload["before"], "payload.before", violations)

        # §7's integrity row. Compared only when both sides parsed as identifiers —
        # otherwise a String "1296269" against the Integer 1296269 would report a
        # mismatch that does not exist, hiding the real defect behind a fabricated one.
        if repository_id && repository && repository[:github_id] != repository_id
          violations << [
            QuarantineReasons::REPOSITORY_ID_MISMATCH,
            "payload.repository_id #{repository_id} does not match repo.id #{repository[:github_id]}"
          ]
        end

        return nil if violations.length > before_count

        { github_push_id: github_push_id, ref: ref, head_sha: head_sha, before_sha: before_sha }
      end

      # An envelope identifier: absence is reported under the caller's own code, because
      # an actor with no id is an invalid actor reference rather than a missing payload
      # field.
      def identifier(value, field, absent_code, violations)
        unless value.is_a?(Integer)
          violations << [ absent_code, "#{field} is #{describe(value)}" ]
          return nil
        end

        in_range(value, field, violations)
      end

      # A payload identifier: present but non-Integer is a shape failure, since absence
      # was already reported by the required-field sweep.
      def identifier_field(value, field, violations)
        unless value.is_a?(Integer)
          return nil if value.nil?

          violations << [ QuarantineReasons::INVALID_FIELD_FORMAT, "#{field} is #{describe(value)}" ]
          return nil
        end

        in_range(value, field, violations)
      end

      def in_range(value, field, violations)
        return value if BIGINT_RANGE.cover?(value)

        violations << [ QuarantineReasons::IDENTIFIER_OUT_OF_RANGE, "#{field} #{value} exceeds a 64-bit identifier" ]
        nil
      end

      def required_string(value, field, absent_code, violations)
        return value if value.is_a?(String) && value.present?

        violations << [ absent_code, "#{field} is #{describe(value)}" ]
        nil
      end

      def required_ref(value, violations)
        return value if value.is_a?(String) && value.present?
        return nil if value.nil?

        violations << [ QuarantineReasons::INVALID_FIELD_FORMAT, "payload.ref is #{describe(value)}" ]
        nil
      end

      # Reuses PushEvent::SHA_FORMAT rather than restating it: 40 hex characters under
      # SHA-1, 64 under SHA-256 (§7, Appendix D item 6). A second copy of that regex is
      # how the parser and the model drift apart.
      def object_name(value, field, violations)
        return value if value.is_a?(String) && PushEvent::SHA_FORMAT.match?(value)
        return nil if value.nil?

        violations << [
          QuarantineReasons::INVALID_FIELD_FORMAT,
          "#{field} is #{describe(value)}, not 40 or 64 hexadecimal characters"
        ]
        nil
      end

      # Optional identity fields are tolerated, not required: a value of the wrong shape
      # is treated as absent, and IDENTITY_MERGE's COALESCE then leaves any previously
      # stored value alone. The whole envelope is retained in raw_payload either way, so
      # nothing is actually lost.
      def optional_string(value)
        value.is_a?(String) && value.present? ? value : nil
      end

      # Error messages name the value's shape, never the value itself for a long field —
      # enough for an operator to act on, without pasting a payload into a log line.
      def describe(value)
        case value
        when nil then "absent"
        when String then value.empty? ? "empty" : value.truncate(64).inspect
        when Integer, Float, true, false then value.inspect
        else "a #{value.class}"
        end
      end
    end
  end
end
