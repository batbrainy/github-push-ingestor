module Github
  module Enrichment
    # Claims a coalesced batch of stable entity rows. The entity table is the work record;
    # one row per GitHub id means repeated event demand is absorbed before planning.
    #
    # Composition policy (plan Appendix G): never-enriched backlog fills the batch FIFO
    # by created_at, id. TTL-stale refresh candidates may only top up slots the backlog
    # could not fill, and only while the other class has no claimable backlog either —
    # otherwise the spare capacity belongs to that class's backlog, not to refresh.
    class BatchClaim
      class Item < Data.define(:id, :github_id, :identifier, :api_url, :previous_stage,
                               :enrichment_status, :enrichment_attempts)
      end

      class Lease < Data.define(:entity_type, :batch, :token, :leased_until, :items)
        def to_log
          { entity_type: entity_type.key, enrichment_batch_id: batch.id,
            batch_correlation_id: batch.correlation_id,
            requested_count: items.length }
        end
      end

      # The stages a backlog claim may take. batch_in_flight is here so an expired
      # lease is reclaimable; the leased_until clause keeps live leases invisible.
      BACKLOG_STAGES = %w[batch_pending retry_scheduled batch_in_flight].freeze
      REFRESH_STAGES = %w[contract_complete batch_in_flight].freeze

      def initialize(configuration: Github.configuration)
        @configuration = configuration
      end

      attr_reader :configuration

      # Never-enriched (or batch-retrying) rows this claim could take right now.
      def backlog_scope(entity_type, now: Time.current)
        due(entity_type.model, now: now)
          .where(enrichment_status: Enrichable::CANDIDATE_STATUSES)
          .where(enrichment_stage: BACKLOG_STAGES)
      end

      # TTL-stale completed rows eligible for a staged refresh: recently active,
      # not backed off, not held by a live lease.
      def refresh_scope(entity_type, now: Time.current)
        due(entity_type.model, now: now)
          .where(enrichment_status: "complete")
          .where(enrichment_stage: REFRESH_STAGES)
          .where(fetched_at: ..(now - entity_type.refresh_ttl_seconds(configuration)))
          .where(last_seen_at: (now - configuration.refresh_active_within_seconds)..)
      end

      def claimable_backlog?(entity_type, now: Time.current)
        backlog_scope(entity_type, now: now).exists?
      end

      # Would #acquire return a lease for this class right now? Backlog always
      # qualifies; refresh qualifies only under the composition policy above.
      def claimable?(entity_type, now: Time.current)
        return true if claimable_backlog?(entity_type, now: now)

        refresh_scope(entity_type, now: now).exists? &&
          EntityType.all.none? { |type| claimable_backlog?(type, now: now) }
      end

      def acquire(entity_type, now: Time.current)
        lease = nil

        entity_type.model.transaction do
          rows = backlog_scope(entity_type, now: now)
                 .order(:created_at, :id)
                 .limit(configuration.search_batch_size)
                 .lock("FOR UPDATE SKIP LOCKED").to_a
          rows += refresh_top_up(entity_type, taken: rows.length, now: now)
          next if rows.empty?

          reclaim_stale_batches(entity_type, rows, now: now)

          identifiers = rows.map { |row| identifier_for(entity_type, row) }
          batch = EnrichmentBatch.create!(
            request_kind: "search", entity_kind: entity_type.key.to_s,
            requested_github_ids: rows.map(&:github_id), requested_identifiers: identifiers,
            requested_count: rows.length,
            request_url: SearchQuery.build(entity_type, identifiers, mode: configuration.mode),
            started_at: now
          )
          token = SecureRandom.uuid
          leased_until = now + configuration.enrichment_lease_seconds

          entity_type.model.where(id: rows.map(&:id)).update_all(
            enrichment_stage: "batch_in_flight", lease_token: token, leased_until: leased_until,
            current_enrichment_batch_id: batch.id
          )

          items = rows.zip(identifiers).map do |row, identifier|
            Item.new(id: row.id, github_id: row.github_id, identifier: identifier,
                     api_url: row.api_url, previous_stage: row.enrichment_stage,
                     enrichment_status: row.enrichment_status,
                     enrichment_attempts: row.enrichment_attempts)
          end
          lease = Lease.new(entity_type: entity_type, batch: batch, token: token,
                            leased_until: leased_until, items: items.freeze)
        end

        lease
      end

      # A deferral must put the row back where it was claimed from, not where a new row
      # starts. Restoring a retry_scheduled/retryable_failure row to batch_pending would
      # leave a status/stage pair Enrichable does not list as legal and would read as
      # work that had never been attempted. previous_stage is the claimed value;
      # batch_in_flight is excluded because that is what an expired lease was reclaimed
      # from, and returning a row to it would re-orphan it.
      def release!(lease, stage: nil, now: Time.current)
        lease.items.each do |item|
          restored = stage || restored_stage(item)
          lease.entity_type.model.where(id: item.id, lease_token: lease.token,
                                        current_enrichment_batch_id: lease.batch.id).update_all(
            enrichment_stage: restored, lease_token: nil, leased_until: nil,
            current_enrichment_batch_id: nil, updated_at: now
          )
        end
      end

      private

      def restored_stage(item)
        return item.previous_stage if item.previous_stage.present? &&
                                      item.previous_stage != "batch_in_flight"

        item.enrichment_status == "complete" ? "contract_complete" : "batch_pending"
      end

      # The single due predicate: a live lease or a scheduled retry excludes a row
      # from every claim; expiry re-admits it.
      def due(model, now:)
        model.where(leased_until: nil).or(model.where(leased_until: ..now))
             .merge(model.where(next_retry_at: nil).or(model.where(next_retry_at: ..now)))
      end

      def refresh_top_up(entity_type, taken:, now:)
        spare = configuration.search_batch_size - taken
        return [] unless spare.positive?
        return [] if EntityType.all.any? { |type| claimable_backlog?(type, now: now) }

        refresh_scope(entity_type, now: now)
          .order(:fetched_at, :id)
          .limit(spare)
          .lock("FOR UPDATE SKIP LOCKED").to_a
      end

      # A row still pointing at an in-flight batch was leased by a worker that never
      # finished; its lease has expired or we could not have locked it. The batch row
      # is finalized as evidence rather than deleted.
      def reclaim_stale_batches(entity_type, rows, now:)
        stale_batch_ids = rows.filter_map(&:current_enrichment_batch_id).uniq
        return if stale_batch_ids.empty?

        reclaimed = EnrichmentBatch.where(id: stale_batch_ids, status: "in_flight")
                                   .update_all(status: "stale_lease", completed_at: now,
                                               updated_at: now)
        return unless reclaimed.positive?

        Rails.logger.warn(event: "enrichment.stale_lease_reclaimed",
                          entity_kind: entity_type.key,
                          enrichment_batch_ids: stale_batch_ids, count: reclaimed)
      end

      def identifier_for(entity_type, row)
        value = entity_type.key == :actor ? row.login : row.full_name
        raise ArgumentError, "#{entity_type.key} #{row.github_id} has no Search identifier" if value.blank?

        value
      end
    end
  end
end
