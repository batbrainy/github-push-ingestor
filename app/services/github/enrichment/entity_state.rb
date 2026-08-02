module Github
  module Enrichment
    # §10's response behaviour, resolved onto one entity row — the entity-side twin of
    # Github::Ingestion::PollState, and written to the same rule: **the state moves only
    # when a fetch attempt actually happened, and only when its outcome is a fact about
    # this entity.**
    #
    # Three rules govern the matrix below.
    #
    #   1. enrichment_attempts moves only for an outcome that says something about *this
    #      entity*. A primary or secondary rate limit is a fact about the IP; PollState
    #      makes exactly this call for the source ("GitHub answered … but nothing is wrong
    #      with the source"), and mirroring it keeps one rule across both state machines.
    #      Inflating an innocent entity's backoff for a condition it did not cause would,
    #      repeated, push it toward the hour-long cap.
    #   2. A retryable outcome never downgrades a `complete` record. This is the one place
    #      the plan is silent, and the argument is concrete: a transient 500 on a *refresh*
    #      would otherwise flip a perfectly enriched entity to retryable_failure, dropping
    #      coverage for a network blip and jumping the row into the high-priority pending
    #      pool ahead of never-enriched candidates. The status conveys nothing that
    #      next_retry_at, last_error and enrichment_attempts do not already carry, and the
    #      row is still TTL-stale so it will be retried anyway. Terminal outcomes — 404,
    #      permanent, malformed — *do* overwrite `complete`, because they invalidate the
    #      stored document's premise.
    #   3. enrichment_attempts counts attempts since the last success, so `complete`
    #      resets it to zero. PollState's consecutive_failures is the precedent.
    #
    # Holds no executor and no transport, so a GitHub request cannot be issued from a
    # state write, and it runs after the fetch has returned — never inside a transaction
    # that spans one.
    class EntityState
      MAX_ERROR_LENGTH = 1_000

      # Dispatch is on the classification symbol and never on FetchResult#successful?,
      # which answers true for :not_modified. A frozen Hash with no default, so an
      # unenumerated classification raises rather than silently taking a branch: PR 4's
      # :redirect never escapes Github::RequestExecutor#follow_redirects (it is either
      # followed or converted into RedirectLimitExceeded → :permanent_error), so its
      # presence here would be a claim about unreachable code.
      DISPOSITIONS = {
        ok: :document,
        not_modified: :retryable,
        not_found: :permanent,
        client_error: :permanent,
        server_error: :retryable,
        transport_error: :retryable,
        permanent_error: :permanent,
        rate_limited: :defer,
        secondary_limited: :secondary,
        budget_denied: :defer,
        gate_unavailable: :defer
      }.freeze

      # What was written, so the runner's Result and its log line need no re-read.
      #
      # lease_held answers the one question the runner has left: whether it still owes a
      # release. Every path that wrote next_retry_at has already replaced the lease, and a
      # lost lease belongs to somebody else — only the do-nothing deferral leaves one
      # outstanding.
      class Written < Data.define(:outcome, :enrichment_status, :next_retry_at, :last_error,
                                  :error_code, :lease_held)
        OUTCOMES = %w[ enriched failed deferred lease_lost ].freeze

        def initialize(outcome:, enrichment_status: nil, next_retry_at: nil,
                       last_error: nil, error_code: nil, lease_held: false)
          raise ArgumentError, "unknown outcome #{outcome.inspect}" unless OUTCOMES.include?(outcome)

          super
        end

        # The deferral that wrote nothing at all, and therefore still owes a release.
        def self.deferred(lease_held: true)
          new(outcome: "deferred", lease_held: lease_held)
        end

        def enriched? = outcome == "enriched"
        def failed? = outcome == "failed"
        def deferred? = outcome == "deferred"
        def lease_lost? = outcome == "lease_lost"

        # Whether an outbound attempt was made *and* charged to this entity. The two
        # deferral classifications spend nothing and record nothing.
        def attempted? = enriched? || failed?

        def to_log
          { enrichment_outcome: outcome, entity_status: enrichment_status,
            next_retry_at: next_retry_at&.utc&.iso8601, error_code: error_code,
            error_message: last_error }.compact
        end
      end

      def initialize(backoff: Backoff.new)
        @backoff = backoff
      end

      attr_reader :backoff

      # @param lease [Github::Enrichment::Claim::Lease]
      # @param fetched [Github::FetchResult]
      # @param document [Github::Enrichment::Document, nil] present only for a 200
      # @param decision [Github::RateLimitPolicy::Decision, nil]
      # @return [Written]
      def record!(lease:, fetched:, document: nil, decision: nil, now: Time.current)
        case DISPOSITIONS.fetch(fetched.classification) { raise ArgumentError, unenumerated(fetched) }
        when :document then from_document(lease, fetched, document, now: now)
        when :permanent then permanent(lease, message_for(fetched), now: now)
        when :retryable then retryable(lease, fetched, now: now)
        when :secondary then secondary(lease, decision)
        when :defer then Written.deferred
        end
      end

      private

      def from_document(lease, fetched, document, now:)
        raise ArgumentError, "a 200 response was not parsed" if document.nil?
        return complete(lease, document, now: now) if document.ok?

        # §10's third error-context row. Both remaining kinds are decided facts about the
        # document rather than transport noise, so both are permanent — and neither
        # touches the payload columns, so a bad refresh cannot delete a good document.
        log_document_rejected(lease, fetched, document)
        permanent(lease, document.error_message, now: now, error_code: document.error_code)
      end

      # next_retry_at is cleared because the next event for this row is a *refresh*, gated
      # by fetched_at + the TTL rather than by a retry instant; leaving the lease in place
      # would delay it by ten minutes and conflate two meanings on one column. last_error
      # is cleared because a stale error on a successful row is a permanent lie.
      def complete(lease, document, now:)
        write(lease, {
          enrichment_status: "complete", enrichment_attempts: 0, next_retry_at: nil,
          last_error: nil, fetched_at: now, updated_at: now
        }.merge(document.attributes), outcome: "enriched")
      end

      def permanent(lease, message, now:, error_code: nil)
        write(lease, {
          enrichment_status: "permanent_failure",
          enrichment_attempts: lease.enrichment_attempts + 1,
          next_retry_at: nil, last_error: truncate(message), updated_at: now
        }, outcome: "failed", error_code: error_code)
      end

      def retryable(lease, fetched, now:)
        log_unexpected_not_modified(lease, fetched) if fetched.classification == :not_modified
        attempts = lease.enrichment_attempts + 1

        write(lease, {
          # Rule 2. Read from the lease rather than re-queried: this worker holds the row,
          # and nothing else may transition it while the lease stands.
          enrichment_status: lease.enrichment_status == "complete" ? "complete" : "retryable_failure",
          enrichment_attempts: attempts,
          next_retry_at: backoff.retry_at(attempts, now: now),
          last_error: truncate(message_for(fetched)), updated_at: now
        }, outcome: "failed")
      end

      # §10: on a secondary limit, "also update the request-specific source or entity retry
      # state". Not redundant with the global block Github::RateLimitPolicy has already
      # recorded — PollState#secondary_retry's reason transfers exactly: ROLL_WINDOW_SQL
      # clears the global block at the window boundary while this component survives it,
      # so a secondary limit that outlives a rollover still defers the entity that
      # provoked it.
      #
      # No attempt is counted and no status moves: rule 1. updated_at is left alone for
      # Github::Enrichment::Claim's reason — this is transient scheduling state, not
      # observable entity state, and bumping it would cost a concurrent page its identity
      # refresh.
      def secondary(lease, decision)
        retry_at = decision&.source_retry_at
        return Written.deferred if retry_at.nil?

        write(lease, { next_retry_at: retry_at }, outcome: "deferred")
      end

      # One guarded statement. The next_retry_at guard is the same one
      # Github::Enrichment::Claim#release! carries and for the same reason: lease_seconds
      # is the worst-case runtime by construction, so a lease expiring mid-flight is
      # reachable, and writing an outcome onto a row another worker has since claimed
      # would be the double-write the lease exists to prevent. Reporting it as lease_lost
      # is the graceful degradation — the budget was spent and the document discarded,
      # which is worth a WARN rather than a silent overwrite.
      def write(lease, attributes, outcome:, error_code: nil)
        updated = lease.entity_type.model
                       .where(id: lease.id, next_retry_at: lease.leased_until)
                       .update_all(attributes)

        return lease_lost(lease) if updated.zero?

        Written.new(outcome: outcome, enrichment_status: attributes[:enrichment_status],
                    next_retry_at: attributes[:next_retry_at],
                    last_error: attributes[:last_error], error_code: error_code,
                    lease_held: false)
      end

      def lease_lost(lease)
        Rails.logger.warn(event: "enrichment.lease_lost", **lease.to_log)
        Written.new(outcome: "lease_lost", lease_held: false)
      end

      # A 304 to a request that carried no validator. Enrichment has no entity ETag column
      # — §7's column list has none, and §10's dated probe established that an
      # unauthenticated 304 debits quota anyway, so a conditional enrichment request would
      # cost the same and return no document. So this is an intermediary answering a
      # conditional request we never made, or GitHub misbehaving: an assumption broke, and
      # it is worth a line even though the row is handled as an ordinary retryable failure.
      #
      # fetched_at is deliberately not bumped on a refresh: we never told the server what
      # we hold, so a 304 is not evidence that what we hold is current.
      def log_unexpected_not_modified(lease, fetched)
        Rails.logger.warn(event: "enrichment.unexpected_not_modified", **lease.to_log,
                          http_status: fetched.status)
      end

      def log_document_rejected(lease, fetched, document)
        Rails.logger.warn(event: "enrichment.document_rejected", **lease.to_log,
                          http_status: fetched.status, **document.to_log)
      end

      def message_for(fetched)
        return fetched.error.message if fetched.error

        "GitHub returned #{fetched.status} (#{fetched.classification})"
      end

      def truncate(message)
        message&.to_s&.truncate(MAX_ERROR_LENGTH)
      end

      def unenumerated(fetched)
        "no enrichment disposition for classification #{fetched.classification.inspect}"
      end
    end
  end
end
