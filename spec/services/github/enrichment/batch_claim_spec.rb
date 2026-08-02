require "rails_helper"

# The two-step batch claim (plan Appendix F/G): never-enriched backlog fills a batch
# FIFO by created_at, id; TTL-stale refresh candidates are admitted only when neither
# class has claimable backlog left. The entity table itself is the work record — the
# lease columns are the claim, so every property here is asserted from committed rows.
RSpec.describe Github::Enrichment::BatchClaim do
  let(:now) { frozen_time }
  let(:configuration) { Github.configuration }
  let(:claim) { described_class.new(configuration: configuration) }
  let(:actor_type) { Github::Enrichment::EntityType.fetch(:actor) }
  let(:repository_type) { Github::Enrichment::EntityType.fetch(:repository) }

  # A batch row another worker started and never finished. correlation_id is passed
  # explicitly because the model validates its presence while the column's
  # gen_random_uuid() default is database-side.
  def orphan_batch(entity_kind: "actor")
    EnrichmentBatch.create!(
      request_kind: "search", entity_kind: entity_kind, started_at: now - 700,
      correlation_id: SecureRandom.uuid,
      request_url: "https://api.github.com/search/users?q=user%3Aoctocat&per_page=1"
    )
  end

  def pending_actor(github_id:, created_at: now - 60, **overrides)
    create_actor(github_id: github_id, login: "user-#{github_id}",
                 created_at: created_at, **overrides)
  end

  # A row the refresh scope should admit at `now`: complete, contract-complete, a day
  # past the default actor TTL, and active within the last week.
  def refreshable_actor(github_id:, fetched_at: now - 172_800, last_seen_at: now - 60, **overrides)
    create_actor(github_id: github_id, login: "user-#{github_id}",
                 enrichment_status: "complete", enrichment_stage: "contract_complete",
                 fetched_at: fetched_at, last_seen_at: last_seen_at, **overrides)
  end

  describe "#acquire on the never-enriched backlog" do
    # Claim order is the plan's one FIFO: immutable created_at, id as the tiebreak.
    it "claims the oldest rows first by created_at then id, at most SEARCH_BATCH_SIZE" do
      small = described_class.new(configuration: configuration_with(SEARCH_BATCH_SIZE: "3"))
      pending_actor(github_id: 1010, created_at: now - 10)
      pending_actor(github_id: 1030, created_at: now - 30)
      pending_actor(github_id: 1020, created_at: now - 20)
      pending_actor(github_id: 1001, created_at: now - 1)

      lease = small.acquire(actor_type, now: now)

      expect(lease.items.map(&:github_id)).to eq([ 1030, 1020, 1010 ])
      expect(GithubActor.find_by(github_id: 1001).enrichment_stage).to eq("batch_pending")
    end

    it "breaks a created_at tie by id, so equal arrivals still claim deterministically" do
      second = pending_actor(github_id: 2002, created_at: now - 30)
      first = pending_actor(github_id: 2001, created_at: now - 30)

      lease = claim.acquire(actor_type, now: now)

      expect(lease.items.map(&:id)).to eq([ second.id, first.id ].sort)
    end

    # One row per GitHub id is what makes the entity table a coalescing work queue:
    # however many events demanded the entity, one Search slot answers all of them.
    it "yields one item per github id however many event observations demanded it" do
      3.times { |n| GithubActor.upsert_stub!(github_id: 583_231, login: "octocat", now: now + n) }

      lease = claim.acquire(actor_type, now: now)

      expect(lease.items.map(&:github_id)).to eq([ 583_231 ])
      expect(GithubActor.where(github_id: 583_231).count).to eq(1)
    end

    it "leases every claimed row: stage, token, expiry, and the batch row it belongs to" do
      pending_actor(github_id: 583_231)

      lease = claim.acquire(actor_type, now: now)
      row = GithubActor.find_by(github_id: 583_231)

      expect(lease.leased_until).to eq(now + configuration.enrichment_lease_seconds)
      expect(row).to have_attributes(
        enrichment_stage: "batch_in_flight", lease_token: lease.token,
        leased_until: now + configuration.enrichment_lease_seconds,
        current_enrichment_batch_id: lease.batch.id
      )
      expect(lease.batch).to have_attributes(
        request_kind: "search", entity_kind: "actor", status: "in_flight",
        requested_count: 1, requested_github_ids: [ 583_231 ],
        requested_identifiers: [ "user-583231" ], started_at: now,
        request_url: "https://api.github.com/search/users?q=user%3Auser-583231&per_page=1"
      )
    end

    it "returns nil on an empty table without creating a batch row" do
      expect(claim.acquire(actor_type, now: now)).to be_nil
      expect(EnrichmentBatch.count).to eq(0)
    end

    it "keeps rows under a live lease invisible to a second claim" do
      pending_actor(github_id: 3001)
      claim.acquire(actor_type, now: now)

      expect(claim.acquire(actor_type, now: now)).to be_nil
      expect(claim.claimable?(actor_type, now: now)).to be(false)
    end

    # A worker that died mid-batch left the row batch_in_flight and its batch in_flight.
    # Lease expiry re-admits the row, and the orphaned batch is finalized as evidence.
    it "reclaims an expired lease and marks its orphaned in-flight batch stale_lease" do
      stale = orphan_batch
      pending_actor(github_id: 4001, enrichment_stage: "batch_in_flight",
                    lease_token: SecureRandom.uuid, leased_until: now - 1,
                    current_enrichment_batch_id: stale.id)
      allow(Rails.logger).to receive(:warn)

      lease = claim.acquire(actor_type, now: now)

      expect(lease.items.map(&:github_id)).to eq([ 4001 ])
      expect(stale.reload).to have_attributes(status: "stale_lease", completed_at: now)
      expect(Rails.logger).to have_received(:warn).with(
        hash_including(event: "enrichment.stale_lease_reclaimed",
                       enrichment_batch_ids: [ stale.id ], count: 1)
      )
    end

    it "re-claims a retry_scheduled row once its next_retry_at is due, but not before" do
      pending_actor(github_id: 5001, enrichment_status: "retryable_failure",
                    enrichment_stage: "retry_scheduled", next_retry_at: now - 1)
      pending_actor(github_id: 5002, created_at: now - 900,
                    enrichment_status: "retryable_failure",
                    enrichment_stage: "retry_scheduled", next_retry_at: now + 300)

      lease = claim.acquire(actor_type, now: now)

      expect(lease.items.map(&:github_id)).to eq([ 5001 ])
    end

    it "raises rather than building a Search query around a blank identifier" do
      pending_actor(github_id: 6001)
      GithubActor.where(github_id: 6001).update_all(login: "")

      expect { claim.acquire(actor_type, now: now) }
        .to raise_error(ArgumentError, /has no Search identifier/)
    end
  end

  describe "refresh admission (the two-step top-up policy)" do
    it "claims a refresh-only batch when neither class has never-enriched backlog" do
      refreshable_actor(github_id: 7001)

      lease = claim.acquire(actor_type, now: now)

      expect(lease.items.map(&:github_id)).to eq([ 7001 ])
      expect(lease.items.first.enrichment_status).to eq("complete")
      expect(GithubActor.find_by(github_id: 7001).enrichment_stage).to eq("batch_in_flight")
    end

    it "orders refresh claims by fetched_at then id — stalest data first" do
      refreshable_actor(github_id: 7011, fetched_at: now - 200_000)
      refreshable_actor(github_id: 7012, fetched_at: now - 400_000)

      lease = claim.acquire(actor_type, now: now)

      expect(lease.items.map(&:github_id)).to eq([ 7012, 7011 ])
    end

    # Spare slots belong to backlog, not to refresh: while this class still has
    # never-enriched work, a claim takes only that work.
    it "does not top a backlog batch up with refresh candidates" do
      pending_actor(github_id: 7021)
      refreshable_actor(github_id: 7022)

      lease = claim.acquire(actor_type, now: now)

      expect(lease.items.map(&:github_id)).to eq([ 7021 ])
      expect(GithubActor.find_by(github_id: 7022).enrichment_stage).to eq("contract_complete")
    end

    # The deny case the policy exists for: the OTHER class still has never-enriched
    # rows, so the spare Search request belongs to that backlog rather than to refresh.
    it "denies refresh while the other class has claimable backlog" do
      refreshable_actor(github_id: 7031)
      create_repository(github_id: 7032)

      expect(claim.acquire(actor_type, now: now)).to be_nil
      expect(claim.claimable?(actor_type, now: now)).to be(false)
    end

    it "denies refresh while fetched_at is still inside the class TTL" do
      refreshable_actor(github_id: 7041, fetched_at: now - 600)

      expect(claim.acquire(actor_type, now: now)).to be_nil
    end

    it "denies refresh for an entity not seen within REFRESH_ACTIVE_WITHIN_SECONDS" do
      refreshable_actor(github_id: 7051, last_seen_at: now - 700_000)

      expect(claim.acquire(actor_type, now: now)).to be_nil
    end

    it "denies refresh while a failed refresh batch's backoff is still holding the row" do
      refreshable_actor(github_id: 7061, next_retry_at: now + 120)

      expect(claim.acquire(actor_type, now: now)).to be_nil
    end
  end

  describe "#claimable? and #claimable_backlog?" do
    it "reports backlog for a due pending row, and overall claimability with it" do
      pending_actor(github_id: 8001)

      expect(claim.claimable_backlog?(actor_type, now: now)).to be(true)
      expect(claim.claimable?(actor_type, now: now)).to be(true)
      expect(claim.claimable_backlog?(repository_type, now: now)).to be(false)
    end

    it "reports refresh-only work as claimable but not as backlog" do
      refreshable_actor(github_id: 8011)

      expect(claim.claimable_backlog?(actor_type, now: now)).to be(false)
      expect(claim.claimable?(actor_type, now: now)).to be(true)
    end
  end

  describe "#release!" do
    # A hand-built lease over rows staged exactly as #acquire leaves them, so release
    # semantics are provable without a round trip through a claim.
    def leased_lease(rows)
      batch = orphan_batch
      token = SecureRandom.uuid
      items = rows.map do |row|
        GithubActor.where(id: row.id).update_all(
          enrichment_stage: "batch_in_flight", lease_token: token,
          leased_until: now + 600, current_enrichment_batch_id: batch.id
        )
        described_class::Item.new(id: row.id, github_id: row.github_id, identifier: row.login,
                                  api_url: row.api_url, previous_stage: "batch_in_flight",
                                  enrichment_status: row.enrichment_status,
                                  enrichment_attempts: row.enrichment_attempts)
      end
      described_class::Lease.new(entity_type: actor_type, batch: batch, token: token,
                                 leased_until: now + 600, items: items.freeze)
    end

    it "restores a never-enriched member to batch_pending and a complete one to contract_complete" do
      pending = pending_actor(github_id: 9001)
      complete = refreshable_actor(github_id: 9002)

      claim.release!(leased_lease([ pending, complete ]), now: now)

      expect(pending.reload).to have_attributes(
        enrichment_stage: "batch_pending", lease_token: nil, leased_until: nil,
        current_enrichment_batch_id: nil
      )
      expect(complete.reload).to have_attributes(
        enrichment_stage: "contract_complete", lease_token: nil, leased_until: nil,
        current_enrichment_batch_id: nil
      )
    end

    it "leaves a row alone when its lease has since been taken by someone else" do
      row = pending_actor(github_id: 9011)
      lease = leased_lease([ row ])
      foreign_token = SecureRandom.uuid
      GithubActor.where(id: row.id).update_all(lease_token: foreign_token)

      claim.release!(lease, now: now)

      expect(row.reload).to have_attributes(enrichment_stage: "batch_in_flight",
                                            lease_token: foreign_token)
    end
  end

  # FOR UPDATE SKIP LOCKED is what lets two workers claim concurrently without either
  # blocking or double-claiming. Real threads on real sessions require transactional
  # fixtures off (spec/support/concurrency_helpers.rb), so this group owns its cleanup.
  describe "two concurrent claims" do
    self.use_transactional_tests = false

    after do
      GithubActor.where(github_id: 700_001..700_015).delete_all
      EnrichmentBatch.delete_all
      restore_connection_pool!
    end

    it "hands each claim a disjoint row set that together covers the backlog" do
      ids = (1..15).map do |n|
        create_actor(github_id: 700_000 + n, login: "worker-#{n}",
                     created_at: now - 60 + n).github_id
      end

      # One stateless claim built on the main thread; each worker thread runs
      # #acquire on its own pooled connection.
      shared_claim = described_class.new(configuration: configuration)
      results = in_parallel(2, threads: 2) { shared_claim.acquire(actor_type, now: now) }

      expect(results).to all(be_a(described_class::Lease))
      claimed = results.map { |lease| lease.items.map(&:github_id) }
      expect(claimed[0] & claimed[1]).to eq([])
      expect(claimed.flatten).to match_array(ids)
    end
  end
end
