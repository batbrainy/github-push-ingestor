module Github
  module Enrichment
    # Claims one row from the bounded detail-fallback lane. Once a batch admits a row
    # here it stays on the detail path until success or an entity-specific terminal
    # outcome — the stage vocabulary keeps the two lanes' claims provably disjoint:
    # the batch path owns batch_pending/retry_scheduled/batch_in_flight, this one owns
    # detail_pending/detail_in_flight.
    class DetailClaim
      Item = Data.define(:id, :github_id, :identifier, :api_url, :enrichment_status,
                         :enrichment_attempts, :detail_attempts)
      Lease = Data.define(:entity_type, :batch, :token, :leased_until, :item)

      CLAIMABLE_STAGES = %w[detail_pending detail_in_flight].freeze

      def initialize(configuration: Github.configuration)
        @configuration = configuration
      end

      attr_reader :configuration

      # FIFO by fallback admission: oldest detail_pending_at first.
      def scope(entity_type, now: Time.current)
        entity_type.model
                   .where(enrichment_stage: CLAIMABLE_STAGES)
                   .where.not(detail_pending_at: nil)
                   .where("next_retry_at IS NULL OR next_retry_at <= ?", now)
                   .where("leased_until IS NULL OR leased_until <= ?", now)
      end

      def claimable?(entity_type, now: Time.current)
        scope(entity_type, now: now).exists?
      end

      def acquire(entity_type, now: Time.current)
        lease = nil
        entity_type.model.transaction do
          row = scope(entity_type, now: now)
                .order(:detail_pending_at, :id)
                .lock("FOR UPDATE SKIP LOCKED").first
          next if row.nil?

          reclaim_stale_batch(entity_type, row, now: now)

          identifier = entity_type.key == :actor ? row.login : row.full_name
          batch = EnrichmentBatch.create!(
            request_kind: "detail", entity_kind: entity_type.key.to_s,
            requested_github_ids: [ row.github_id ], requested_identifiers: [ identifier ],
            requested_count: 1, request_url: row.api_url, started_at: now
          )
          token = SecureRandom.uuid
          leased_until = now + @configuration.enrichment_lease_seconds
          row.update_columns(enrichment_stage: "detail_in_flight", lease_token: token,
                             leased_until: leased_until, current_enrichment_batch_id: batch.id)
          item = Item.new(id: row.id, github_id: row.github_id, identifier: identifier,
                          api_url: row.api_url, enrichment_status: row.enrichment_status,
                          enrichment_attempts: row.enrichment_attempts,
                          detail_attempts: row.detail_attempts)
          lease = Lease.new(entity_type: entity_type, batch: batch, token: token,
                            leased_until: leased_until, item: item)
        end
        lease
      end

      def release!(lease, now: Time.current)
        lease.entity_type.model.where(id: lease.item.id, lease_token: lease.token,
                                      current_enrichment_batch_id: lease.batch.id).update_all(
          enrichment_stage: "detail_pending", lease_token: nil, leased_until: nil,
          current_enrichment_batch_id: nil, updated_at: now
        )
      end

      private

      def reclaim_stale_batch(entity_type, row, now:)
        return if row.current_enrichment_batch_id.nil?

        reclaimed = EnrichmentBatch.where(id: row.current_enrichment_batch_id, status: "in_flight")
                                   .update_all(status: "stale_lease", completed_at: now,
                                               updated_at: now)
        return unless reclaimed.positive?

        Rails.logger.warn(event: "enrichment.stale_lease_reclaimed",
                          entity_kind: entity_type.key,
                          enrichment_batch_ids: [ row.current_enrichment_batch_id ],
                          count: reclaimed)
      end
    end
  end
end
