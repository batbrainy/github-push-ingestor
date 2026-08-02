require "rails_helper"

# §12's "Enrichment job executed twice" exercises one redelivery case. The ingestion-wide
# guarantees are narrower: a duplicate event ID cannot create another push_events row or
# register new entity activity. Executions, run summaries, quarantine counters, budget
# use, and logs can repeat. Here the second execution really happens, and the claims are
# the staged pipeline's: a surplus cycle finds no claimable stage and no admissible
# budget, so it cannot double-apply a projection or double-spend past either ledger's cap.
#
# The redelivery is modelled as the *same job instance* performed twice: one job id, two
# executions, which is what Solid Queue produces when a worker dies after the job ran and
# before its claim was released.
RSpec.describe "an enrichment cycle delivered twice", type: :integration do
  let(:now) { frozen_time }
  let(:transport) { fixture_transport }
  let(:configuration) { configuration_with("GITHUB_MODE" => "fixture", "SEARCH_PACING_SECONDS" => "0") }
  let(:job) { EnrichmentCycleJob.new }

  before do
    fixture_runner(transport: transport, now: now).call(event_source: fixture_event_source)

    allow(Github).to receive(:configuration).and_return(configuration)
    allow(Github::Enrichment::CycleRunner).to receive(:new)
      .and_return(fixture_cycle_runner(transport: transport, now: now,
                                       configuration: configuration))

    job.perform_now
  end

  it "did the whole staged pipeline's work on the first delivery" do
    expect(GithubActor.find_by(github_id: 583_231))
      .to have_attributes(enrichment_status: "complete", enrichment_stage: "contract_complete")
    expect(GithubActor.find_by(github_id: 7_700_421).enrichment_stage).to eq("terminal")
    expect(current_search_budget.used).to eq(2)
    expect(current_budget.enrichment_used).to eq(2)
  end

  it "leaves the durable state byte-identical after the second" do
    before_rows = [ GithubActor.order(:id).map(&:attributes),
                    GithubRepository.order(:id).map(&:attributes) ]

    job.perform_now

    expect([ GithubActor.order(:id).map(&:attributes),
             GithubRepository.order(:id).map(&:attributes) ]).to eq(before_rows)
  end

  # The staged FIFO is what makes this true — not a dedup table, and not the queue. A
  # contract_complete row is not claimable and a terminal row never is, so the second
  # delivery has nothing to claim, nothing to observe, and nothing to spend.
  it "spends no second request on either ledger and appends no observation" do
    before_counts = [ current_search_budget.used, current_budget.enrichment_used,
                      EnrichmentObservation.count, EnrichmentBatch.count ]

    job.perform_now

    expect([ current_search_budget.used, current_budget.enrichment_used,
             EnrichmentObservation.count, EnrichmentBatch.count ]).to eq(before_counts)
    expect(transport.requests.size).to eq(5)
  end

  it "reports an empty cycle rather than pretending it did the work again" do
    job.perform_now

    expect(job.outcome).to include(batches_attempted: 0, details_attempted: 0,
                                   batch_stop_reason: "no_batch_work")
  end

  it "creates no duplicate entity row" do
    expect { job.perform_now }.not_to change(GithubActor, :count).from(3)
  end

  # A redelivery that lands while the first execution is still in flight: the lease on
  # lease_token/leased_until makes the rows invisible to every claim scope, so the
  # second cycle finds nothing rather than fetching the same batch twice.
  describe "arriving while the first execution still holds the lease" do
    before do
      GithubActor.update_all(enrichment_status: "pending", enrichment_stage: "batch_in_flight",
                             lease_token: SecureRandom.uuid, leased_until: now + 600,
                             fetched_at: nil)
    end

    it "finds nothing to claim and spends nothing" do
      expect { job.perform_now }.not_to change { current_search_budget.used }.from(2)
      expect(job.outcome).to include(batches_attempted: 0)
    end
  end

  # The ledgers are the last line even when a surplus delivery does find claimable work:
  # a re-pended backlog against spent windows stops at admission, before any claim.
  describe "arriving after the caps are already spent" do
    before do
      GithubActor.update_all(enrichment_status: "pending", enrichment_stage: "batch_pending",
                             batch_pending_at: now, fetched_at: nil)
      GithubSearchBudget.where(id: GithubSearchBudget::SINGLETON_ID).update_all(used: 8)
      GithubApiBudget.where(id: GithubApiBudget::SINGLETON_ID).update_all(enrichment_used: 4)
    end

    it "cannot spend past either cap" do
      job.perform_now

      expect(current_search_budget.used).to eq(8)
      expect(current_budget.enrichment_used).to eq(4)
      expect(job.outcome).to include(batches_attempted: 0,
                                     batch_stop_reason: "search_ceiling_exhausted")
    end
  end

  # §10: "actor or repo URL returns 404/410 → entity permanent_failure". A redelivery
  # must not re-attempt a decided entity, and must not reset the ladder that decided it.
  describe "after a permanent failure" do
    let(:ghost) { GithubActor.find_by(github_id: 7_700_421) }

    it "does not re-attempt the entity" do
      before_attributes = ghost.attributes

      job.perform_now

      expect(ghost.reload).to have_attributes(enrichment_status: "permanent_failure",
                                              enrichment_stage: "terminal")
      expect(ghost.attributes).to eq(before_attributes)
    end
  end
end
