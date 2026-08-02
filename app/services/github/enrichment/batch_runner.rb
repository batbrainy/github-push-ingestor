module Github
  module Enrichment
    # Executes one Search request for up to SEARCH_BATCH_SIZE stable entity ids, preserves
    # every returned item, and projects only items that validate against the claimed id.
    #
    # incomplete_results=true is an envelope fact about the *query* (it timed out), not
    # about any returned item: an item that validated against its immutable GitHub id is
    # applied regardless, and only items missing from the response fall back to the
    # bounded core detail lane. The envelope flag is retained on the batch row.
    class BatchRunner
      # Bodies are evidence only when something went wrong; successful batches already
      # retain every item verbatim as observations. Bounded so a hostile or broken
      # response cannot grow the batch table without limit.
      RESPONSE_BODY_LIMIT = 65_536

      class Result < Data.define(:status, :entity_type, :batch_id, :requested_count,
                                 :returned_count, :valid_count, :fallback_count,
                                 :deferral_reason)
        def attempted? = %w[completed failed].include?(status)
      end

      def initialize(executor: Github.executor, configuration: Github.configuration,
                     claim: BatchClaim.new(configuration: configuration),
                     search_ledger: SearchBudgetLedger.new(configuration: configuration),
                     backoff: Backoff.new(configuration: configuration),
                     clock: -> { Time.current })
        @executor = executor
        @configuration = configuration
        @claim = claim
        @search_ledger = search_ledger
        @backoff = backoff
        @clock = clock
      end

      def call(entity_class:)
        entity_type = EntityType.fetch(entity_class)
        lease = @claim.acquire(entity_type, now: @clock.call)
        return idle(entity_type) if lease.nil?

        fetched = @executor.call(request_for(lease))
        @search_ledger.block_from!(fetched, now: @clock.call)
        finish(lease, fetched)
      rescue StandardError => error
        abandon(lease, error) if lease
        raise
      end

      private

      def idle(entity_type)
        Result.new(status: "idle", entity_type: entity_type.key, batch_id: nil,
                   requested_count: 0, returned_count: 0, valid_count: 0,
                   fallback_count: 0, deferral_reason: nil)
      end

      def request_for(lease)
        Request.new(
          url: lease.batch.request_url,
          request_class: lease.entity_type.search_request_class,
          origin: :application,
          context: lease.to_log
        )
      end

      def finish(lease, fetched)
        snapshot = fetched.rate_limit(observed_at: @clock.call)
        record_response_metadata(lease.batch, fetched, snapshot)

        return defer(lease, fetched) if fetched.deferred? || %i[rate_limited secondary_limited].include?(fetched.classification)
        return unsearchable_batch(lease, fetched) if unsearchable?(fetched)
        return retry_later(lease, fetched) unless fetched.ok?

        response = SearchResponse.parse(fetched.body)
        return malformed_batch(lease, response) unless response.ok?

        apply_response(lease, response)
      end

      def apply_response(lease, response)
        now = @clock.call
        counts = { valid: 0, missing: 0, invalid: 0, fallback: 0 }
        consumed = Set.new

        ActiveRecord::Base.transaction do
          by_id = response.items.each_with_index.each_with_object({}) do |(raw, index), result|
            result[raw["id"]] ||= [ raw, index ] if raw.is_a?(Hash) && raw["id"].is_a?(Integer)
          end

          lease.items.each do |item|
            raw, index = by_id[item.github_id]
            unless raw
              raw, index = identifier_match(lease.entity_type, response.items, item.identifier)
            end

            if raw.nil?
              counts[:missing] += 1
              counts[:fallback] += 1
              admit_fallback(lease, item, "missing_search_result", now: now)
              next
            end

            consumed << index
            disposition = validate_item(lease.entity_type, item, raw)
            observation = ObservationRecorder.record!(
              entity_type: lease.entity_type, entity_github_id: item.github_id,
              source: :search, raw_payload: raw, observed_at: now,
              validation_outcome: disposition.fetch(:outcome), batch: lease.batch,
              requested_identifier: item.identifier
            )

            if disposition.fetch(:apply)
              applied = apply_projection(lease, item, disposition.fetch(:document), observation, now: now)
              counts[applied ? :valid : :invalid] += 1
            else
              counts[:invalid] += 1
              counts[:fallback] += 1
              admit_fallback(lease, item, disposition.fetch(:outcome), now: now)
            end
          end

          response.items.each_with_index do |raw, index|
            next if consumed.include?(index)

            actual_id = raw.is_a?(Hash) && raw["id"].is_a?(Integer) ? raw["id"] : nil
            ObservationRecorder.record!(
              entity_type: lease.entity_type, entity_github_id: actual_id,
              source: :search, raw_payload: raw, observed_at: now,
              validation_outcome: "unrequested_result", batch: lease.batch
            )
            counts[:invalid] += 1
          end

          lease.batch.update!(
            status: "succeeded", completed_at: now, total_count: response.total_count,
            incomplete_results: response.incomplete_results,
            returned_count: response.items.length, valid_count: counts[:valid],
            missing_count: counts[:missing], invalid_count: counts[:invalid]
          )
        end

        result = Result.new(status: "completed", entity_type: lease.entity_type.key,
                            batch_id: lease.batch.id, requested_count: lease.items.length,
                            returned_count: response.items.length, valid_count: counts[:valid],
                            fallback_count: counts[:fallback], deferral_reason: nil)
        Rails.logger.info(event: "enrichment.batch_completed", **result.to_h,
                          incomplete_results: response.incomplete_results)
        result
      end

      def validate_item(entity_type, item, raw)
        return { apply: false, outcome: "identity_mismatch" } unless raw.is_a?(Hash) && raw["id"] == item.github_id
        if entity_type.key == :repository && raw["full_name"].to_s.casecmp(item.identifier.to_s) != 0
          return { apply: false, outcome: "renamed_repository" }
        end

        document = entity_type.document.parse(raw, github_id: item.github_id)
        return { apply: false, outcome: document.error_code || document.kind.to_s } unless document.ok?

        { apply: true, outcome: "applied", document: document }
      end

      def identifier_match(entity_type, items, identifier)
        field = entity_type.key == :actor ? "login" : "full_name"
        items.each_with_index.find do |raw, _index|
          raw.is_a?(Hash) && raw[field].to_s.casecmp(identifier.to_s).zero?
        end
      end

      def apply_projection(lease, item, document, observation, now:)
        model = lease.entity_type.model
        attributes = document.attributes.merge(
          enrichment_status: "complete", enrichment_stage: "contract_complete",
          enrichment_attempts: 0, next_retry_at: nil, last_error: nil,
          fetched_at: now, batch_applied_at: now,
          contract_completed_at: keep_first(model, :contract_completed_at, now),
          latest_observation_id: observation.id, latest_observation_source: "search",
          latest_observed_at: now, lease_token: nil, leased_until: nil,
          current_enrichment_batch_id: nil, updated_at: now
        )

        model.where(id: item.id, lease_token: lease.token,
                    current_enrichment_batch_id: lease.batch.id).update_all(attributes) == 1
      end

      # COALESCE(column, bound-now): the first completion instant is the durable one —
      # a refresh must not re-count an entity as newly completed (§45 throughput).
      def keep_first(model, column, now)
        Arel::Nodes::NamedFunction.new(
          "COALESCE", [ model.arel_table[column], Arel::Nodes.build_quoted(now) ]
        )
      end

      def admit_fallback(lease, item, reason, now:)
        lease.entity_type.model.where(id: item.id, lease_token: lease.token,
                                      current_enrichment_batch_id: lease.batch.id).update_all(
          enrichment_stage: "detail_pending", detail_pending_at: now,
          last_error: reason, lease_token: nil, leased_until: nil,
          current_enrichment_batch_id: nil, updated_at: now
        )
        Rails.logger.info(event: "enrichment.fallback_admitted",
                          entity_type: lease.entity_type.key,
                          lease.entity_type.log_key => item.github_id,
                          reason: reason, enrichment_batch_id: lease.batch.id)
      end

      def record_response_metadata(batch, fetched, snapshot)
        batch.update!(
          response_status: fetched.status,
          response_body: retained_body(fetched),
          rate_limit_resource: snapshot.resource, rate_limit_limit: snapshot.limit,
          rate_limit_remaining: snapshot.remaining, rate_limit_used: snapshot.used,
          rate_limit_reset_at: snapshot.reset_at
        )
      end

      # Successful bodies live on as per-item observations; only failure evidence is
      # retained here, bounded.
      def retained_body(fetched)
        return nil if fetched.ok?

        fetched.body.to_s.truncate(RESPONSE_BODY_LIMIT)
      end

      def defer(lease, fetched)
        now = @clock.call
        reason = fetched.classification.to_s
        lease.batch.update!(status: "deferred", completed_at: now,
                            last_error: fetched.error&.message || reason)
        @claim.release!(lease, now: now)
        Rails.logger.info(event: "enrichment.batch_deferred", **lease.to_log,
                          deferral_reason: reason)
        Result.new(status: "deferred", entity_type: lease.entity_type.key,
                   batch_id: lease.batch.id, requested_count: lease.items.length,
                   returned_count: 0, valid_count: 0, fallback_count: 0,
                   deferral_reason: reason)
      end

      def retry_later(lease, fetched)
        reason = fetched.error&.message || fetched.classification.to_s
        fail_batch(lease, reason, response_status: fetched.status)
      end

      def malformed_batch(lease, response)
        fail_batch(lease, response.error_message,
                   deferral_reason: "malformed_search_response")
      end

      # Observed live, not in the probe: Search answers 422 rather than an empty result
      # set when *every* requested identifier is unsearchable — the state a renamed or
      # deleted entity is in (facebook/react, which now redirects to react/react). A
      # batch of ten mixes them in and simply omits them, so this only occurs once the
      # remaining members are all in that state.
      #
      # Every deterministic client error is treated the same way, not just that one
      # message. A rejected query is a fact about *this batch's* identifiers and URL,
      # and the retry ladder would resend both unchanged: the same 4xx, hourly, with no
      # terminal condition and no way to self-heal. Routing the members to the detail
      # lane is bounded (its own allowance, its own attempt ladder, its own terminal
      # outcome) and is the one path that can actually resolve them. Matching on the
      # English phrase alone would also break the moment GitHub rewords it.
      #
      # Rate-limit responses are excluded by the caller: 403/429 classify as
      # rate_limited or secondary_limited and defer rather than reaching here.
      UNSEARCHABLE_SIGNAL = "cannot be searched".freeze

      def unsearchable?(fetched)
        fetched.classification == :client_error
      end

      def unsearchable_reason(fetched)
        fetched.body.to_s.include?(UNSEARCHABLE_SIGNAL) ? "unsearchable_identifier" : "search_query_rejected"
      end

      def unsearchable_batch(lease, fetched)
        now = @clock.call
        reason = unsearchable_reason(fetched)
        lease.items.each do |item|
          admit_fallback(lease, item, reason, now: now)
        end
        lease.batch.update!(status: "failed", completed_at: now,
                            last_error: reason,
                            returned_count: 0, missing_count: lease.items.length)
        Rails.logger.warn(event: "enrichment.batch_unsearchable", **lease.to_log,
                          reason: reason, response_status: fetched.status)
        Result.new(status: "completed", entity_type: lease.entity_type.key,
                   batch_id: lease.batch.id, requested_count: lease.items.length,
                   returned_count: 0, valid_count: 0,
                   fallback_count: lease.items.length, deferral_reason: nil)
      end

      def fail_batch(lease, reason, response_status: nil, deferral_reason: nil)
        now = @clock.call
        lease.batch.update!(status: "failed", completed_at: now, last_error: reason)
        schedule_batch_retry(lease, now: now)
        Rails.logger.warn(event: "enrichment.batch_failed", **lease.to_log,
                          reason: reason, response_status: response_status)
        Result.new(status: "failed", entity_type: lease.entity_type.key,
                   batch_id: lease.batch.id, requested_count: lease.items.length,
                   returned_count: 0, valid_count: 0, fallback_count: 0,
                   deferral_reason: deferral_reason || reason)
      end

      # A failed batch reschedules every member. Never-enriched members rest in
      # retry_scheduled (the batch path owns that stage); already-complete refresh
      # members return to contract_complete, their next_retry_at holding the next
      # refresh claim off until the backoff clears.
      def schedule_batch_retry(lease, now:)
        lease.items.each do |item|
          attempts = item.enrichment_attempts + 1
          complete = item.enrichment_status == "complete"
          lease.entity_type.model.where(id: item.id, lease_token: lease.token,
                                        current_enrichment_batch_id: lease.batch.id).update_all(
            enrichment_status: complete ? "complete" : "retryable_failure",
            enrichment_stage: complete ? "contract_complete" : "retry_scheduled",
            enrichment_attempts: attempts,
            next_retry_at: @backoff.retry_at(attempts, now: now),
            retry_scheduled_at: now,
            lease_token: nil, leased_until: nil, current_enrichment_batch_id: nil,
            updated_at: now
          )
        end
      end

      # A crash between claim and outcome must not leave the batch row in_flight
      # forever: finalize it as failed evidence, give the rows back, re-raise.
      def abandon(lease, error)
        now = @clock.call
        lease.batch.update!(status: "failed", completed_at: now,
                            last_error: error.class.name)
        @claim.release!(lease, now: now)
      end
    end
  end
end
