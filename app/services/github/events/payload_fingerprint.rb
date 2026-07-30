module Github
  module Events
    # Quarantine's sole identity (IMPLEMENTATION_PLAN.md §7).
    #
    #   payload_fingerprint =
    #     SHA-256( compact UTF-8 JSON produced after recursively sorting all object keys )
    #
    # One canonicalization definition, no alternates — the plan says so twice and
    # CLAUDE.md repeats it, because a second algorithm would mean two rows for one
    # payload and an occurrence count that no longer counts occurrences. This module is
    # the only place that definition exists.
    #
    # A malformed event may be malformed precisely because it lacks an event ID, so the
    # fingerprint is the *only* unique constraint on quarantined_events (§7, Appendix D
    # item 7). That makes it a primary key, and a primary key must be a pure function of
    # its input: no clock, no database, no Hash iteration order, no configuration.
    #
    # What gets fingerprinted is the **whole envelope element**, the same value written
    # to quarantined_events.raw_payload — not envelope["payload"]. §7 requires that the
    # same github_event_id arriving with a different malformed payload be a *different*
    # row; corpus event 58000000007 carries "payload": {}, so fingerprinting only the
    # payload would collapse every typeless envelope with an empty payload onto one row
    # and discard the rest, permanently, since QuarantinedEvent.record! never refreshes
    # raw_payload or error_code.
    #
    # Because the digest is taken over the *parsed* value, fingerprint identity and
    # jsonb identity agree by construction: two bodies differing only in whitespace or
    # key order are one quarantine row, which is exactly the semantic-retention
    # tradeoff ADR 0001 already accepted.
    module PayloadFingerprint
      class << self
        # @param document [Object] any value JSON.parse can produce, including nil —
        #   Github::EventSources::Base#events returns array elements untouched, and a
        #   valid JSON array can legitimately contain null (§7's invalid envelope).
        # @return [String] 64 lowercase hexadecimal characters
        # @raise [ArgumentError] for a value outside the JSON data model
        def fingerprint(document)
          Digest::SHA256.hexdigest(canonical(document))
        end

        # The canonical text itself. Public because it is what makes the algorithm
        # auditable: a spec asserts against this string rather than against an opaque
        # hex constant, so the assertion documents the algorithm instead of memorising
        # its output.
        #
        # JSON.generate, deliberately, not to_json. to_json routes a Hash through
        # ActiveSupport's encoder, which applies as_json coercions and HTML-escapes
        # <, > and & whenever ActiveSupport.escape_html_entities_in_json is true — an
        # application-level setting. Both behaviours are deterministic today, and both
        # are one initializer away from silently re-keying every row already in the
        # table. JSON.generate is the library primitive with no such surface, and it is
        # compact (no space, indent, object_nl or array_nl) and UTF-8 by default.
        #
        # @return [String] compact UTF-8 JSON
        def canonical(document)
          JSON.generate(sorted(document))
        end

        private

        # Recursion over a closed value set — exactly what JSON.parse produces, and
        # nothing else. An unexpected class raises rather than being coerced: a
        # fingerprint that silently accepts a Time or a Symbol is a fingerprint whose
        # meaning depends on who called it.
        def sorted(value)
          case value
          when Hash then sorted_object(value)
          when Array then value.map { |element| sorted(element) }
          when String, Integer, true, false, nil then value
          when Float then finite!(value)
          else
            raise ArgumentError, "#{value.class} is outside the JSON data model and cannot be fingerprinted"
          end
        end

        # Keys are inserted in sort order and JSON.generate preserves insertion order,
        # so rebuilding the Hash *is* the canonicalization. Array order is never
        # touched: it is semantically meaningful in JSON and in jsonb.
        #
        # Plain sort — String#<=> is bytewise, so it is locale-independent and equal to
        # code-point order for UTF-8. Not sort_by(&:to_s): sort_by is not stable, so two
        # keys colliding after to_s would order nondeterministically, and a
        # nondeterministic primary key is a corrupted one. A non-String key is
        # unreachable from JSON.parse; raising documents that precondition instead of
        # papering over the one input that could make this function ambiguous.
        def sorted_object(hash)
          keys = hash.keys
          offender = keys.find { |key| !key.is_a?(String) }
          if offender
            raise ArgumentError,
                  "object keys must be Strings to be canonicalized, got #{offender.class} #{offender.inspect}"
          end

          keys.sort.to_h { |key| [ key, sorted(hash.fetch(key)) ] }
        end

        # JSON.parse("1e400") succeeds and yields Float::INFINITY, and JSON.generate
        # then raises JSON::GeneratorError. So such a value has no fingerprint, which
        # means a malformed envelope carrying one has no quarantine row available to it —
        # its only terminal outcome is events_failed, and the log line should name the
        # value rather than surface a bare generator error from three frames down.
        #
        # Storage is a separate and quieter problem, verified against PostgreSQL 16 rather
        # than assumed: ActiveSupport's JSON encoder writes Infinity into jsonb as null.
        # It does not raise. That is within ADR 0001's semantic-retention tradeoff, but it
        # is one more reason not to derive an identity from a value the database will not
        # keep.
        def finite!(float)
          return float if float.finite?

          raise ArgumentError, "#{float} is not representable in JSON and cannot be fingerprinted"
        end
      end
    end
  end
end
