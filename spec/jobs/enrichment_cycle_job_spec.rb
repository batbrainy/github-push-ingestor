require "rails_helper"

# One staged-enrichment cycle (§5, Appendix G). The cycle's own behaviour — lanes, pacing,
# the wall-clock budget — is Github::Enrichment::CycleRunner's, specified there; what this
# file pins is the job boundary: which queue, that one delivery is one cycle, that the
# cycle's counters reach the job's completion line, that a duplicate delivery is harmless,
# and that no source lock is ever taken.
RSpec.describe EnrichmentCycleJob do
  def cycle(overrides = {})
    defaults = {
      batches_attempted: 2, batches_completed: 1, batches_deferred: 0, batches_failed: 1,
      items_requested: 10, items_valid: 8, fallbacks_admitted: 2, details_attempted: 1,
      details_completed: 1, details_terminal: 0, details_deferred: 0,
      batch_stop_reason: "search_reserve_reached", detail_stop_reason: "no_detail_work",
      duration_ms: 1234
    }

    Github::Enrichment::CycleRunner::Cycle.new(**defaults.merge(overrides))
  end

  def stub_runner(runner)
    allow(Github::Enrichment::CycleRunner).to receive(:new).and_return(runner)
    runner
  end

  # Enrichment is deliberately isolated: a deep durable backlog may keep this queue busy
  # for many quota windows, and it must never delay polling or the control tick.
  it "runs on the dedicated enrichment queue" do
    expect(described_class.new.queue_name).to eq("enrichment")
  end

  it "runs exactly one cycle per delivery" do
    runner = stub_runner(instance_double(Github::Enrichment::CycleRunner))
    expect(runner).to receive(:call).once.and_return(cycle)

    described_class.new.perform_now
  end

  # §11: the cycle's counters ride the job's own completion line, so a reviewer's trace
  # from job_id to what the cycle did is zero hops.
  it "joins the cycle's counters to the job on one line" do
    stub_runner(instance_double(Github::Enrichment::CycleRunner, call: cycle))
    allow(Rails.logger).to receive(:info)

    job = described_class.new
    job.perform_now

    expect(Rails.logger).to have_received(:info).with(
      hash_including(event: "job.completed", job_id: job.job_id, job_class: "EnrichmentCycleJob",
                     batches_attempted: 2, batches_completed: 1, items_requested: 10,
                     items_valid: 8, fallbacks_admitted: 2, details_completed: 1,
                     batch_stop_reason: "search_reserve_reached",
                     detail_stop_reason: "no_detail_work")
    )
  end

  # Duplicate deliveries are harmless by construction: the surplus cycle's admission
  # checks and claims read the committed entity rows and the ledgers, find nothing to do,
  # and exit having created no batch row and spent no budget. Asserted over the real
  # runner and the real database rather than a stub, because the guarantee lives in the
  # committed state, not in the queue.
  it "makes a duplicate delivery a fast no-op against committed state" do
    active_budget_window(now: Time.current)
    create_actor(github_id: 583_231, enrichment_status: "complete",
                 enrichment_stage: "contract_complete", fetched_at: Time.current,
                 last_seen_at: Time.current)

    2.times { described_class.new.perform_now }

    expect(EnrichmentBatch.count).to eq(0)
    expect(current_budget.enrichment_used).to eq(0)
    expect(WebMock).not_to have_requested(:any, //)
  end

  # §8 step 1: "Enrichment jobs skip this step — they take only the request gate."
  # Asserted at the job boundary as well as inside the runners, because this is where a
  # future "just lock the source while we enrich it" would be written.
  it "never takes a source lock" do
    stub_runner(instance_double(Github::Enrichment::CycleRunner, call: cycle))
    expect(Github::SourceLock).not_to receive(:acquire)

    described_class.new.perform_now

    expect(Github::LockOrder.held_keys).to be_empty
  end

  # §6 requires a corpus gap to be raised rather than laundered into a failed fetch; the
  # batch runner has already finalized the batch row and released the lease by the time
  # it arrives here.
  it "lets a fixture corpus gap fail the job" do
    runner = stub_runner(instance_double(Github::Enrichment::CycleRunner))
    allow(runner).to receive(:call).and_raise(Github::Errors::FixtureMiss, "no such body")

    expect { described_class.new.perform_now }.to raise_error(Github::Errors::FixtureMiss)
  end
end
