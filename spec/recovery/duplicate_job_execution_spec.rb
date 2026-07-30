require "rails_helper"

# §12's "Enrichment job executed twice", which is §8's processing semantics stated as a test:
# at-least-once execution + idempotent writes + unique constraints = effectively-once
# persisted outcomes. Never exactly-once execution — the second execution really happens here,
# and what is asserted is that it changes nothing.
#
# The redelivery is modelled as the *same job instance* performed twice: one job id, two
# executions, which is what Solid Queue produces when a worker dies after the job ran and
# before its claim was released.
RSpec.describe "an enrichment job delivered twice", type: :integration do
  let(:transport) { fixture_transport }
  let(:job) { EnrichActorJob.new }

  before do
    active_budget_window(now: frozen_time)
    create_actor(github_id: 583_231, last_seen_at: frozen_time,
                 api_url: "https://api.github.com/users/octocat")

    allow(Github).to receive(:configuration).and_return(configuration_with("GITHUB_MODE" => "fixture"))
    allow(Github::EnrichmentRunner).to receive(:new)
      .and_return(fixture_enrichment_runner(transport: transport, now: frozen_time))

    job.perform_now
  end

  it "enriched the actor on the first delivery" do
    expect(GithubActor.sole)
      .to have_attributes(enrichment_status: "complete", name: "The Octocat", fetched_at: frozen_time)
    expect(current_budget.enrichment_used).to eq(1)
  end

  it "leaves the durable state byte-identical after the second" do
    before_attributes = GithubActor.sole.attributes

    job.perform_now

    expect(GithubActor.sole.attributes).to eq(before_attributes)
  end

  # The freshness cache is what makes this true — not a dedup table, and not the queue. A
  # fresh record is not a candidate, so the second delivery has nothing to claim.
  it "spends no second request and no second reservation" do
    expect { job.perform_now }.not_to change { current_budget.enrichment_used }.from(1)
    expect(transport.requests.size).to eq(1)
  end

  it "reports idle rather than pretending it did the work again" do
    job.perform_now

    expect(job.outcome).to include(enrichment_outcome: "idle")
  end

  it "creates no duplicate entity row" do
    expect { job.perform_now }.not_to change(GithubActor, :count).from(1)
  end

  # A redelivery that lands while the first execution is still in flight: the lease on
  # next_retry_at excludes the row from all four selector queries, so the second finds nothing
  # rather than fetching the same entity twice.
  describe "arriving while the first execution still holds the lease" do
    it "finds nothing to do and spends nothing" do
      GithubActor.update_all(enrichment_status: "pending", fetched_at: nil,
                             next_retry_at: frozen_time + 600)

      expect { job.perform_now }.not_to change { current_budget.enrichment_used }.from(1)
      expect(job.outcome).to include(enrichment_outcome: "idle")
    end
  end

  # §10: "actor or repo URL returns 404/410 → entity permanent_failure". A redelivery must not
  # re-attempt a decided entity, and must not reset the attempt counter that decided it.
  describe "after a permanent failure" do
    let(:ghost) { GithubActor.find_by(github_id: 7_700_421) }

    it "does not re-attempt the entity" do
      create_actor(github_id: 7_700_421, login: "ghostuser", last_seen_at: frozen_time,
                   api_url: "https://api.github.com/users/ghostuser")
      job.perform_now
      before_attributes = ghost.attributes

      job.perform_now

      expect(ghost.reload).to have_attributes(enrichment_status: "permanent_failure")
      expect(ghost.attributes).to eq(before_attributes)
    end
  end
end
