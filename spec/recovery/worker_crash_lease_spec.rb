require "rails_helper"

# §12's "Worker failure before completion". A real crash runs no ensure block, so it is
# modelled as what it leaves behind — a claim lease with no worker behind it — rather than by
# stubbing an exception, which would exercise the release path the crash skipped.
#
# The recovery has no cleanup code anywhere, and that is the design: the lease is written onto
# next_retry_at, so it expires by arithmetic. Nothing has to notice the worker died.
RSpec.describe "a lease left behind by a crashed worker", type: :integration do
  let(:transport) { fixture_transport }
  let(:configuration) { Github.configuration }
  let(:claim) { Github::Enrichment::Claim.new(configuration: configuration) }
  let(:actor_type) { Github::Enrichment::EntityType.fetch(:actor) }
  let!(:actor) do
    create_actor(github_id: 583_231, last_seen_at: frozen_time,
                 api_url: "https://api.github.com/users/octocat")
  end

  # The crash: a lease taken, and then nothing.
  let!(:lease) { claim.acquire(actor_type, pool: :pending, now: frozen_time) }

  before do
    active_budget_window(now: frozen_time)
    allow(Github).to receive(:configuration).and_return(configuration_with("GITHUB_MODE" => "fixture"))
  end

  # The stub has to come off before the next runner is built: #fixture_enrichment_runner goes
  # through Github::EnrichmentRunner.new itself, so a second call with the previous stub still
  # in place would hand back the previous runner — and its clock, which is the one thing every
  # example here is varying.
  def enrich_at(instant)
    allow(Github::EnrichmentRunner).to receive(:new).and_call_original
    runner = fixture_enrichment_runner(transport: transport, now: instant)
    allow(Github::EnrichmentRunner).to receive(:new).and_return(runner)

    job = EnrichActorJob.new
    job.perform_now
    job
  end

  # Derived from §2A's pinned defaults — attempts × redirect hops × (gate wait + open + read)
  # plus the backoff — so a configuration change moves this expectation with the code instead
  # of leaving a stale literal behind.
  it "holds the entity for exactly the derived lease window" do
    expect(lease.leased_until - frozen_time).to eq(claim.lease_seconds)
  end

  describe "while the lease is still live" do
    it "finds nothing to do, and says so" do
      expect(enrich_at(frozen_time).outcome).to include(enrichment_outcome: "idle")
    end

    it "leaves the entity exactly as the dead worker left it" do
      before_attributes = actor.reload.attributes

      enrich_at(frozen_time)

      expect(actor.reload.attributes).to eq(before_attributes)
      expect(actor.enrichment_attempts).to eq(0)
      expect(actor.last_error).to be_nil
    end

    it "spends no budget on an entity it cannot claim" do
      expect { enrich_at(frozen_time) }.not_to change { current_budget.enrichment_used }.from(0)
      expect(transport.requests).to be_empty
    end
  end

  describe "once the lease expires" do
    it "enriches the entity, with no sweeper and no cleanup step in between" do
      enrich_at(lease.leased_until)

      expect(actor.reload)
        .to have_attributes(enrichment_status: "complete", name: "The Octocat")
    end

    it "spends exactly one request for the whole crash-and-recovery sequence" do
      enrich_at(frozen_time)
      enrich_at(lease.leased_until)

      expect(current_budget.enrichment_used).to eq(1)
      expect(transport.requests.size).to eq(1)
    end

    # The crash cost the entity nothing: attempts count attempts *since the last success*, and
    # a claim that was never used is not one.
    it "charges the entity no attempt for the crash" do
      enrich_at(lease.leased_until)

      expect(actor.reload.enrichment_attempts).to eq(0)
    end
  end
end
