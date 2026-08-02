require "rails_helper"

# §12's recovery tests: "Event committed but job not scheduled (reconciler sweep)" and
# "Pending enrichment rediscovered (entity-scoped)".
#
# The crash is expressed the way a crash actually presents itself: rows committed, queue
# empty. Nothing is stubbed to raise, because a SIGKILL runs no ensure block and no
# rescue — what it leaves behind is exactly this state, and §2A's claim is that this
# state is recoverable *because* the entity rows are the durable record of pending work:
# the staged FIFO (enrichment_stage plus batch_pending_at) is readable by any later
# reconciler tick.
#
# The page is ingested at Time.current because the reconciler reads the worker's clock
# and Solid Queue constructs the job, so there is no test clock to inject into that
# boundary.
RSpec.describe "recovering enrichment work that was never enqueued", type: :integration do
  let(:transport) { fixture_transport }
  let(:ingested_at) { Time.current }

  before do
    active_budget_window(now: ingested_at)
    fixture_runner(transport: transport, now: ingested_at).call(event_source: fixture_event_source)

    # This line is the crash: the four push events and their six stub entities are committed,
    # and the enqueue the run had just made is gone.
    clear_enqueued_jobs
  end

  it "leaves the work durable in the business tables, where nothing could lose it" do
    expect(PushEvent.count).to eq(4)
    expect(GithubActor.where(enrichment_stage: "batch_pending").count).to eq(3)
    expect(GithubRepository.where(enrichment_stage: "batch_pending").count).to eq(3)
    expect(enqueued_jobs).to be_empty
  end

  it "rediscovers it on the next reconciler tick" do
    expect { ReconcilePendingEnrichmentsJob.perform_now }
      .to have_enqueued_job(EnrichmentCycleJob).exactly(:once)
  end

  it "rediscovers pending rows even when their durable insertion time is very old" do
    GithubActor.update_all(created_at: ingested_at - 30.days,
                           last_seen_at: ingested_at - 30.days)
    GithubRepository.update_all(created_at: ingested_at - 30.days,
                                last_seen_at: ingested_at - 30.days)

    expect { ReconcilePendingEnrichmentsJob.perform_now }
      .to have_enqueued_job(EnrichmentCycleJob).exactly(:once)
  end

  # §8: "a small, entity-scoped set, not N event rows per entity." Six entities behind
  # four events are one cycle — not one job per class, per entity, or per event. The
  # cycle works both lanes itself; queue depth is set by the budgets, not the backlog.
  it "schedules one cycle, not one per class, per pending entity, or per event" do
    ReconcilePendingEnrichmentsJob.perform_now

    expect(enqueued_jobs.map { _1[:job] }).to eq([ EnrichmentCycleJob ])
  end

  # The sweep reads state and schedules; it never writes entity rows. If it did, a worker
  # that came back after an hour would silently reset the backoff of everything it found.
  it "changes no entity row while rediscovering the work" do
    before_rows = GithubActor.order(:id)
                             .pluck(:id, :enrichment_status, :enrichment_stage,
                                    :enrichment_attempts, :updated_at)

    ReconcilePendingEnrichmentsJob.perform_now

    expect(GithubActor.order(:id)
                      .pluck(:id, :enrichment_status, :enrichment_stage,
                             :enrichment_attempts, :updated_at))
      .to eq(before_rows)
  end

  it "keeps scheduling on every tick until the work is actually done" do
    2.times { ReconcilePendingEnrichmentsJob.perform_now }

    expect(enqueued_jobs.count { _1[:job] == EnrichmentCycleJob }).to eq(2)
  end

  # The end of the story rather than the middle: the rediscovered work runs, and the
  # entities reach the same durable state the un-crashed run would have produced.
  it "completes the recovered work when the scheduled cycle runs" do
    recovery_configuration = configuration_with("GITHUB_MODE" => "fixture",
                                                "SEARCH_PACING_SECONDS" => "0")
    allow(Github).to receive(:configuration).and_return(recovery_configuration)
    allow(Github::Enrichment::CycleRunner).to receive(:new)
      .and_return(fixture_cycle_runner(transport: transport, now: Time.current,
                                       configuration: recovery_configuration))

    3.times do
      ReconcilePendingEnrichmentsJob.perform_now
      perform_enqueued_jobs
    end

    expect(GithubActor.find_by(github_id: 583_231))
      .to have_attributes(enrichment_status: "complete", enrichment_stage: "contract_complete")
    expect(GithubRepository.find_by(github_id: 1_296_269).enrichment_status).to eq("complete")
    expect(GithubActor.find_by(github_id: 7_700_421).enrichment_stage).to eq("terminal")
  end

  describe "when there is nothing left to recover" do
    before do
      GithubActor.update_all(enrichment_status: "complete", enrichment_stage: "contract_complete",
                             fetched_at: ingested_at)
      GithubRepository.update_all(enrichment_status: "complete", enrichment_stage: "contract_complete",
                                  fetched_at: ingested_at)
    end

    it "schedules nothing" do
      expect { ReconcilePendingEnrichmentsJob.perform_now }.not_to have_enqueued_job
    end
  end

  # A live worker's in-flight rows are not pending work: the batch lease is written onto
  # lease_token/leased_until, and every claim scope excludes a live lease. Without this
  # the reconciler would pile cycles onto entities another worker already holds.
  describe "while a live worker holds every candidate" do
    before do
      lease = { enrichment_stage: "batch_in_flight", lease_token: SecureRandom.uuid,
                leased_until: ingested_at + 600 }
      GithubActor.update_all(lease)
      GithubRepository.update_all(lease)
    end

    it "schedules nothing" do
      expect { ReconcilePendingEnrichmentsJob.perform_now }.not_to have_enqueued_job
    end
  end
end
