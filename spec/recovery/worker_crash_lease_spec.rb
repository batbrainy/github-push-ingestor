require "rails_helper"

# §12's "Worker failure before completion". A real crash runs no ensure block, so it is
# modelled as what it leaves behind — a batch lease with no worker behind it — rather
# than by stubbing an exception, which would exercise the abandon path the crash skipped.
#
# The staged lease is three columns and one row of evidence: lease_token + leased_until
# + current_enrichment_batch_id on every claimed entity, and an in_flight
# enrichment_batches row. Recovery still has no cleanup code anywhere: the lease expires
# by arithmetic, the next claim reclaims the rows, and the orphaned batch row is
# finalized as stale_lease evidence rather than deleted.
RSpec.describe "a lease left behind by a crashed worker", type: :integration do
  let(:now) { frozen_time }
  let(:configuration) { configuration_with("GITHUB_MODE" => "fixture", "SEARCH_PACING_SECONDS" => "0") }
  let(:transport) { fixture_transport }
  let(:claim) { Github::Enrichment::BatchClaim.new(configuration: configuration) }
  let(:actor_type) { Github::Enrichment::EntityType.fetch(:actor) }

  # The corpus Search key carries exactly this trio in this order.
  let!(:actors) do
    [
      create_actor(github_id: 583_231, login: "octocat", display_login: "octocat",
                   api_url: "https://api.github.com/users/octocat",
                   last_seen_at: now, created_at: now - 3),
      create_actor(github_id: 1_024_025, login: "monalisa", display_login: "monalisa",
                   api_url: "https://api.github.com/users/monalisa",
                   last_seen_at: now, created_at: now - 2),
      create_actor(github_id: 7_700_421, login: "ghostuser", display_login: "ghostuser",
                   api_url: "https://api.github.com/users/ghostuser",
                   last_seen_at: now, created_at: now - 1)
    ]
  end

  # The crash: a batch claimed, and then nothing at all.
  let!(:lease) { claim.acquire(actor_type, now: now) }

  def batch_runner(at:)
    fixture_batch_runner(transport: transport, now: at, configuration: configuration)
  end

  it "holds every claimed entity for exactly the configured lease window" do
    expect(lease.leased_until - now).to eq(configuration.enrichment_lease_seconds)
    expect(GithubActor.where(lease_token: lease.token).count).to eq(3)
    expect(GithubActor.pluck(:enrichment_stage).uniq).to eq([ "batch_in_flight" ])
  end

  it "leaves the in-flight batch row behind as evidence" do
    expect(lease.batch.reload).to have_attributes(
      status: "in_flight", request_kind: "search", entity_kind: "actor",
      requested_count: 3, completed_at: nil
    )
  end

  describe "while the lease is still live" do
    it "is invisible to another claim" do
      expect(claim.acquire(actor_type, now: now)).to be_nil
    end

    it "makes a full runner cycle report idle, and spend nothing" do
      result = batch_runner(at: now).call(entity_class: GithubActor)

      expect(result.status).to eq("idle")
      expect(transport.requests).to be_empty
      expect(GithubSearchBudget.find_by(id: GithubSearchBudget::SINGLETON_ID)&.used.to_i).to eq(0)
    end

    it "leaves the entities exactly as the dead worker left them" do
      before_rows = GithubActor.order(:id).map(&:attributes)

      batch_runner(at: now).call(entity_class: GithubActor)

      expect(GithubActor.order(:id).map(&:attributes)).to eq(before_rows)
    end
  end

  describe "once the lease expires" do
    let(:expiry) { lease.leased_until }

    it "reclaims the rows, finalizes the orphan batch as stale_lease, and completes the work" do
      result = batch_runner(at: expiry).call(entity_class: GithubActor)

      expect(result).to have_attributes(status: "completed", requested_count: 3,
                                        valid_count: 2, fallback_count: 1)
      expect(lease.batch.reload).to have_attributes(status: "stale_lease", completed_at: expiry)
      expect(GithubActor.find_by(github_id: 583_231))
        .to have_attributes(enrichment_status: "complete", enrichment_stage: "contract_complete")
      expect(GithubActor.find_by(github_id: 7_700_421).enrichment_stage).to eq("detail_pending")
    end

    it "spends exactly one search request for the whole crash-and-recovery sequence" do
      batch_runner(at: now).call(entity_class: GithubActor)   # idle, while leased
      batch_runner(at: expiry).call(entity_class: GithubActor)

      expect(current_search_budget.used).to eq(1)
      expect(transport.requests.size).to eq(1)
    end

    # The crash cost the entities nothing: attempts count attempts *since the last
    # success*, and a claim that was never used is not one.
    it "charges the entities no attempt for the crash" do
      batch_runner(at: expiry).call(entity_class: GithubActor)

      expect(GithubActor.where(github_id: [ 583_231, 1_024_025 ]).pluck(:enrichment_attempts).uniq)
        .to eq([ 0 ])
    end

    # The token guard: if the dead worker were merely slow and finished after the
    # reclaim, its guarded writes name a lease_token and batch id the rows no longer
    # carry, so they match zero rows — the same UPDATE shape BatchRunner uses.
    it "makes the old writer's late guarded write match nothing" do
      batch_runner(at: expiry).call(entity_class: GithubActor)

      late_write = GithubActor.where(id: lease.items.first.id, lease_token: lease.token,
                                     current_enrichment_batch_id: lease.batch.id)
                              .update_all(last_error: "late write from a dead worker")

      expect(late_write).to eq(0)
      expect(GithubActor.find_by(github_id: 583_231).last_error).to be_nil
    end
  end

  # The same arithmetic on the one-row detail lane: a live detail lease is invisible,
  # an expired one is reclaimed and its orphan batch finalized as evidence.
  describe "a crashed detail-lane worker" do
    let(:detail_claim) { Github::Enrichment::DetailClaim.new(configuration: configuration) }

    before do
      claim.release!(lease, now: now)
      GithubActor.where(github_id: 7_700_421)
                 .update_all(enrichment_stage: "detail_pending", detail_pending_at: now)
    end

    it "expires by arithmetic and finalizes the orphan batch as stale_lease" do
      dead = detail_claim.acquire(actor_type, now: now)

      expect(detail_claim.acquire(actor_type, now: now)).to be_nil

      reclaimed = detail_claim.acquire(actor_type, now: dead.leased_until)
      expect(reclaimed.item.github_id).to eq(7_700_421)
      expect(dead.batch.reload.status).to eq("stale_lease")
    end
  end
end
