require "rails_helper"

# §12's "Multiple pollers attempt the same source", at the level PR 8 introduces it: the
# recurring tick, running in a worker container that may not be the only one.
#
# The contended lock is taken from a genuinely separate PostgreSQL session, never a thread —
# session advisory locks are re-entrant within a session, so a thread-based version of this
# spec would pass even if SourceLock did nothing at all (spec/support/advisory_lock_helpers.rb
# spells the trap out).
RSpec.describe "a tick against a source another poller owns", type: :integration do
  let(:transport) { fixture_transport }
  let!(:event_source) { fixture_event_source }
  let(:key) { Github::AdvisoryLock.key_for(event_source.id) }

  before do
    active_budget_window(now: frozen_time)
    allow(Github).to receive(:configuration).and_return(configuration_with("GITHUB_MODE" => "fixture"))

    allow(Github::IngestionRunner).to receive(:new).and_call_original
    runner = fixture_runner(transport: transport)
    allow(Github::IngestionRunner).to receive(:new).and_return(runner)
  end

  def tick(&block)
    other_session_holding(Github::AdvisoryLock::SOURCE_LOCK_NAMESPACE, key) do
      job = PollEventSourceJob.new
      job.perform_now
      block&.call(job)
      job
    end
  end

  # §2A: "The poller attempts once and exits if unavailable." A raise would record a failed
  # execution once a minute for as long as a one-shot ran, which is the system's own mutual
  # exclusion working — not a defect.
  it "completes the tick instead of failing the job" do
    expect { tick }.not_to raise_error
  end

  it "reports the contention at INFO, with the job id" do
    allow(Rails.logger).to receive(:info)

    job = tick

    expect(Rails.logger).to have_received(:info).with(
      hash_including(event: "ingestion.source_busy", event_source_id: event_source.id, job_id: job.job_id)
    )
  end

  # The run row is opened inside the lock, which is what makes this provable rather than
  # merely likely.
  it "leaves no trace at all: no run, no request, no budget spent, no schedule moved" do
    tick

    expect(IngestionRun.count).to eq(0)
    expect(transport.requests).to be_empty
    expect(current_budget.poll_used).to eq(0)
    expect(event_source.reload)
      .to have_attributes(consecutive_failures: 0, last_polled_at: nil, cadence_due_at: nil)
  end

  it "schedules no enrichment, because no event was created" do
    expect { tick }.not_to have_enqueued_job
  end

  # Contention on one source must not cost the others their turn in this tick.
  it "still polls the sources the other poller does not hold" do
    other = create_event_source(source_type: "github_fixture_events", next_poll_at: nil)

    tick

    expect(IngestionRun.pluck(:event_source_id)).to eq([ other.id ])
  end

  it "leaves the lock-order tracking clean, on the busy path as much as the polled one" do
    tick

    expect(Github::LockOrder.held_keys).to be_empty
  end
end
