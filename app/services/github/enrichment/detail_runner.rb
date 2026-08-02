module Github
  module Enrichment
    # The bounded exception path. It uses only the API URL retained from the event, and
    # therefore cannot invent a login/name URL after a missing or renamed Search result.
    #
    # Outcomes (§10, restated by Appendix G): a confirmed 404/410 is the one immediate
    # entity-specific terminal outcome; every other failure climbs the retry ladder and
    # becomes terminal only after DETAIL_FALLBACK_MAX_ATTEMPTS. Quota denial defers and
    # is never an attempt.
    class DetailRunner
      RESPONSE_BODY_LIMIT = BatchRunner::RESPONSE_BODY_LIMIT

      # Outcomes no retry can change, so the ladder is skipped entirely (§10's
      # classification table, and the dispositions the retired per-entity path used):
      # a deleted entity, a rejected request, and a URL this application's SSRF policy
      # refuses or a redirect chain that exceeded its bound. The last is not
      # hypothetical — a live actor login containing brackets yields an unparsable
      # payload URL, and retrying it would spend the scarce core detail allowance three
      # times to refuse the same stored string.
      TERMINAL_CLASSIFICATIONS = %i[ not_found client_error permanent_error ].freeze

      Result = Data.define(:status, :entity_type, :github_id, :batch_id, :reason)

      def initialize(executor: Github.executor, configuration: Github.configuration,
                     claim: DetailClaim.new(configuration: configuration),
                     rate_limit_policy: RateLimitPolicy.new,
                     backoff: Backoff.new(configuration: configuration),
                     clock: -> { Time.current })
        @executor = executor
        @configuration = configuration
        @claim = claim
        @rate_limit_policy = rate_limit_policy
        @backoff = backoff
        @clock = clock
      end

      def call(entity_class:, borrow: false)
        type = EntityType.fetch(entity_class)
        lease = @claim.acquire(type, now: @clock.call)
        return Result.new(status: "idle", entity_type: type.key, github_id: nil,
                          batch_id: nil, reason: nil) if lease.nil?

        fetched = @executor.call(Request.new(
          url: lease.item.api_url, request_class: type.request_class, origin: :payload,
          borrow: borrow,
          context: { enrichment_batch_id: lease.batch.id,
                     batch_correlation_id: lease.batch.correlation_id,
                     type.log_key => lease.item.github_id }
        ))
        decision = @rate_limit_policy.apply!(fetched, now: @clock.call)
        finish(lease, fetched, decision)
      rescue StandardError => error
        abandon(lease, error) if lease
        raise
      end

      private

      def finish(lease, fetched, _decision)
        now = @clock.call
        snapshot = fetched.rate_limit(observed_at: now)
        lease.batch.update!(
          response_status: fetched.status,
          response_body: fetched.ok? ? nil : fetched.body.to_s.truncate(RESPONSE_BODY_LIMIT),
          rate_limit_resource: snapshot.resource, rate_limit_limit: snapshot.limit,
          rate_limit_remaining: snapshot.remaining, rate_limit_used: snapshot.used,
          rate_limit_reset_at: snapshot.reset_at
        )

        if fetched.deferred? || %i[rate_limited secondary_limited].include?(fetched.classification)
          lease.batch.update!(status: "deferred", completed_at: now,
                              last_error: fetched.error&.message || fetched.classification.to_s)
          @claim.release!(lease, now: now)
          Rails.logger.info(event: "enrichment.detail_deferred",
                            entity_type: lease.entity_type.key,
                            lease.entity_type.log_key => lease.item.github_id,
                            deferral_reason: fetched.classification.to_s)
          return result(lease, "deferred", fetched.classification.to_s)
        end

        if fetched.ok?
          document = lease.entity_type.document.parse(fetched.body, github_id: lease.item.github_id)
          raw = decode_raw(fetched.body)
          observation = ObservationRecorder.record!(
            entity_type: lease.entity_type, entity_github_id: lease.item.github_id,
            source: :detail, raw_payload: raw, observed_at: now,
            validation_outcome: document.ok? ? "applied" : (document.error_code || document.kind.to_s),
            batch: lease.batch, requested_identifier: lease.item.identifier
          )
          return apply_success(lease, document, observation, now: now) if document.ok?

          return retry_or_terminal(lease, document.error_message, now: now)
        end

        reason = fetched.error&.message || fetched.classification.to_s
        if TERMINAL_CLASSIFICATIONS.include?(fetched.classification)
          return terminal(lease, terminal_reason(fetched, reason), now: now)
        end

        retry_or_terminal(lease, reason, now: now)
      end

      def apply_success(lease, document, observation, now:)
        model = lease.entity_type.model
        attributes = document.attributes.merge(
          enrichment_status: "complete", enrichment_stage: "contract_complete",
          enrichment_attempts: 0, detail_attempts: lease.item.detail_attempts + 1,
          next_retry_at: nil, last_error: nil, fetched_at: now, batch_applied_at: now,
          contract_completed_at: keep_first(model, :contract_completed_at, now),
          latest_observation_id: observation.id, latest_observation_source: "detail",
          latest_observed_at: now, lease_token: nil, leased_until: nil,
          current_enrichment_batch_id: nil, updated_at: now
        )
        applied = model.where(id: lease.item.id, lease_token: lease.token,
                              current_enrichment_batch_id: lease.batch.id)
                       .update_all(attributes) == 1
        lease.batch.update!(status: "succeeded", completed_at: now, returned_count: 1,
                            valid_count: applied ? 1 : 0, invalid_count: applied ? 0 : 1)
        if applied
          Rails.logger.info(event: "enrichment.detail_completed",
                            entity_type: lease.entity_type.key,
                            lease.entity_type.log_key => lease.item.github_id,
                            enrichment_batch_id: lease.batch.id,
                            detail_attempts: lease.item.detail_attempts + 1)
        end
        result(lease, applied ? "completed" : "lease_lost", applied ? nil : "lease_lost")
      end

      def keep_first(model, column, now)
        Arel::Nodes::NamedFunction.new(
          "COALESCE", [ model.arel_table[column], Arel::Nodes.build_quoted(now) ]
        )
      end

      # 404/410 says the entity is gone; the other terminal classifications name
      # themselves through the executor's error message.
      def terminal_reason(fetched, reason)
        fetched.classification == :not_found ? "entity_gone_#{fetched.status}" : reason
      end

      # An entity-specific, permanent fact is the only allowed terminal outcome: the
      # event data, observations, reason, and timestamps all survive it.
      def terminal(lease, reason, now:)
        write_failure(lease, reason, terminal: true, now: now)
        Rails.logger.warn(event: "enrichment.detail_terminal",
                          entity_type: lease.entity_type.key,
                          lease.entity_type.log_key => lease.item.github_id,
                          detail_attempts: lease.item.detail_attempts + 1, reason: reason)
        result(lease, "terminal", reason)
      end

      def retry_or_terminal(lease, message, now:)
        attempts = lease.item.detail_attempts + 1
        return terminal(lease, message, now: now) if attempts >= @configuration.detail_fallback_max_attempts

        write_failure(lease, message, terminal: false, now: now)
        Rails.logger.warn(event: "enrichment.detail_retry_scheduled",
                          entity_type: lease.entity_type.key,
                          lease.entity_type.log_key => lease.item.github_id,
                          detail_attempts: attempts, reason: message.to_s.truncate(200))
        result(lease, "retry_scheduled", message)
      end

      # Retryable detail failures rest in detail_pending — never retry_scheduled,
      # which the batch path owns. Re-batching a row whose search result already
      # missed would spend search budget reproducing the same miss.
      def write_failure(lease, message, terminal:, now:)
        attempts = lease.item.detail_attempts + 1
        complete = lease.item.enrichment_status == "complete"
        attributes = {
          detail_attempts: attempts, enrichment_attempts: lease.item.enrichment_attempts + 1,
          enrichment_status: terminal ? "permanent_failure" :
            (complete ? "complete" : "retryable_failure"),
          enrichment_stage: terminal ? "terminal" : "detail_pending",
          next_retry_at: terminal ? nil : @backoff.retry_at(attempts, now: now),
          retry_scheduled_at: terminal ? nil : now,
          terminal_at: terminal ? now : nil,
          last_error: message.to_s.truncate(1_000), lease_token: nil, leased_until: nil,
          current_enrichment_batch_id: nil, updated_at: now
        }
        lease.entity_type.model.where(id: lease.item.id, lease_token: lease.token,
                                      current_enrichment_batch_id: lease.batch.id).update_all(attributes)
        lease.batch.update!(status: "failed", completed_at: now, last_error: message.to_s,
                            invalid_count: 1)
      end

      def decode_raw(body)
        body.is_a?(Hash) ? body : JSON.parse(body.to_s)
      rescue JSON::ParserError
        { "unparsed_body" => body.to_s }
      end

      def abandon(lease, error)
        now = @clock.call
        lease.batch.update!(status: "failed", completed_at: now,
                            last_error: error.class.name)
        @claim.release!(lease, now: now)
      end

      def result(lease, status, reason)
        Result.new(status: status, entity_type: lease.entity_type.key,
                   github_id: lease.item.github_id, batch_id: lease.batch.id, reason: reason)
      end
    end
  end
end
