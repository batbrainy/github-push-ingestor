require "rails_helper"

# The bounded detail-fallback lane's claim: one row per call, FIFO by the instant the
# batch admitted it. Its stage vocabulary (detail_pending/detail_in_flight) is disjoint
# from the batch path's by construction, so nothing here can double-claim a batch row.
RSpec.describe Github::Enrichment::DetailClaim do
  let(:now) { frozen_time }
  let(:configuration) { Github.configuration }
  let(:claim) { described_class.new(configuration: configuration) }
  let(:actor_type) { Github::Enrichment::EntityType.fetch(:actor) }

  def fallback_actor(github_id:, detail_pending_at: now - 60, **overrides)
    create_actor(github_id: github_id, login: "user-#{github_id}",
                 api_url: "https://api.github.com/users/user-#{github_id}",
                 enrichment_stage: "detail_pending",
                 detail_pending_at: detail_pending_at, **overrides)
  end

  # See batch_claim_spec: correlation_id is supplied because the model validates its
  # presence while the column default is database-side.
  def orphan_batch
    EnrichmentBatch.create!(request_kind: "detail", entity_kind: "actor",
                            started_at: now - 700, correlation_id: SecureRandom.uuid,
                            request_url: "https://api.github.com/users/orphan")
  end

  describe "#scope" do
    it "admits only detail-stage rows that carry an admission instant and are due" do
      fallback_actor(github_id: 1)
      fallback_actor(github_id: 2, enrichment_stage: "detail_in_flight",
                     leased_until: now - 1)
      # Backed off, still leased, never admitted, or resting on the batch path — all out.
      fallback_actor(github_id: 3, next_retry_at: now + 300)
      fallback_actor(github_id: 4, enrichment_stage: "detail_in_flight",
                     leased_until: now + 300)
      create_actor(github_id: 5, login: "user-5")
      fallback_actor(github_id: 6, detail_pending_at: nil)

      expect(claim.scope(actor_type, now: now).pluck(:github_id)).to match_array([ 1, 2 ])
      expect(claim.claimable?(actor_type, now: now)).to be(true)
    end
  end

  describe "#acquire" do
    it "claims the oldest admission first, by detail_pending_at then id" do
      fallback_actor(github_id: 11, detail_pending_at: now - 100)
      fallback_actor(github_id: 12, detail_pending_at: now - 300)

      first = claim.acquire(actor_type, now: now)
      second = claim.acquire(actor_type, now: now)

      expect(first.item.github_id).to eq(12)
      expect(second.item.github_id).to eq(11)
    end

    it "leases the row and records the attempt as a detail-kind batch row" do
      fallback_actor(github_id: 21)

      lease = claim.acquire(actor_type, now: now)
      row = GithubActor.find_by(github_id: 21)

      expect(row).to have_attributes(
        enrichment_stage: "detail_in_flight", lease_token: lease.token,
        leased_until: now + configuration.enrichment_lease_seconds,
        current_enrichment_batch_id: lease.batch.id
      )
      expect(lease.batch).to have_attributes(
        request_kind: "detail", entity_kind: "actor", status: "in_flight",
        requested_github_ids: [ 21 ], requested_identifiers: [ "user-21" ],
        requested_count: 1, request_url: "https://api.github.com/users/user-21",
        started_at: now
      )
      expect(lease.item).to have_attributes(github_id: 21, identifier: "user-21",
                                            api_url: "https://api.github.com/users/user-21")
    end

    it "returns nil while the only candidate is under a live lease" do
      fallback_actor(github_id: 31)
      claim.acquire(actor_type, now: now)

      expect(claim.acquire(actor_type, now: now)).to be_nil
      expect(claim.claimable?(actor_type, now: now)).to be(false)
    end

    it "reclaims an expired detail lease and finalizes its orphaned batch as stale_lease" do
      stale = orphan_batch
      fallback_actor(github_id: 41, enrichment_stage: "detail_in_flight",
                     lease_token: SecureRandom.uuid, leased_until: now - 1,
                     current_enrichment_batch_id: stale.id)
      allow(Rails.logger).to receive(:warn)

      lease = claim.acquire(actor_type, now: now)

      expect(lease.item.github_id).to eq(41)
      expect(lease.batch.id).not_to eq(stale.id)
      expect(stale.reload).to have_attributes(status: "stale_lease", completed_at: now)
      expect(Rails.logger).to have_received(:warn).with(
        hash_including(event: "enrichment.stale_lease_reclaimed",
                       enrichment_batch_ids: [ stale.id ], count: 1)
      )
    end
  end

  describe "#release!" do
    it "restores the row to detail_pending with its lease cleared" do
      fallback_actor(github_id: 51)
      lease = claim.acquire(actor_type, now: now)

      claim.release!(lease, now: now)

      expect(GithubActor.find_by(github_id: 51)).to have_attributes(
        enrichment_stage: "detail_pending", detail_pending_at: now - 60,
        lease_token: nil, leased_until: nil, current_enrichment_batch_id: nil
      )
    end
  end
end
