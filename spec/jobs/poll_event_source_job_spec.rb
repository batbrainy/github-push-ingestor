require "rails_helper"

# §2A's recurring tick. The runner is a double in most of these because the contract under
# test is the *tick's*: which sources it asks about, what it does with each answer, and what
# it refuses to turn into a failed execution. Github::IngestionRunner's own behaviour has its
# own spec, and the last group here drives the real one over the fixture corpus so the two
# contracts are known to fit.
#
# Due-ness is expressed relative to real time rather than to frozen_time, because the job
# reads Time.current: it is the one object in this flow that cannot be handed a clock, since
# Solid Queue constructs it.
RSpec.describe PollEventSourceJob do
  let(:runner) { instance_double(Github::IngestionRunner) }
  let(:result) { Github::IngestionRunner::Result.new(run_id: "run-1", status: "completed") }

  before { allow(Github::IngestionRunner).to receive(:new).and_return(runner) }

  it "runs on the polling queue, isolated from backlog work" do
    expect(described_class.new.queue_name).to eq("polling")
  end

  def poll!(job = described_class.new)
    job.perform_now
    job
  end

  # Nothing seeds event_sources, so without this a tick would run forever against an empty
  # table (Github::Ingestion::SourceProvisioner's comment explains why lazily, at the point of
  # use, is the only correct answer here).
  describe "on a clean database" do
    it "provisions the source it is about to poll" do
      allow(runner).to receive(:call).and_return(result)

      expect { poll! }.to change(EventSource, :count).by(1)
      expect(EventSource.sole.source_type).to eq("github_public_events")
    end
  end

  describe "choosing what to poll" do
    it "polls a due source once, attempting the lock only once (§2A's poller contract)" do
      source = create_event_source(next_poll_at: nil)
      expect(runner).to receive(:call).with(event_source: source).once.and_return(result)

      poll!
    end

    it "asks the runner about nothing when no source is due" do
      create_event_source(next_poll_at: 1.hour.from_now)
      expect(runner).not_to receive(:call)

      poll!
    end

    # Filtered rather than left to the runner, which logs ingestion.source_unavailable at
    # warn — once a minute, forever, for a source only an operator can restore.
    it "asks the runner about nothing when the only source is out of service" do
      create_event_source(status: "failed", next_poll_at: nil)
      expect(runner).not_to receive(:call)

      poll!
    end

    # A development database routinely holds both rows: the README's reviewer path creates a
    # fixture source with `GITHUB_MODE=fixture docker compose run --rm ingest`.
    it "never polls a source belonging to another mode" do
      create_event_source(source_type: "github_fixture_events", next_poll_at: nil)
      allow(runner).to receive(:call).and_return(result)

      poll!

      expect(runner).to have_received(:call)
        .with(event_source: having_attributes(source_type: "github_public_events")).once
    end
  end

  describe "what it reports" do
    before { create_event_source(next_poll_at: nil) }

    it "puts the job id and every run it opened on one line" do
      allow(runner).to receive(:call).and_return(result)
      allow(Rails.logger).to receive(:info)

      job = poll!

      expect(Rails.logger).to have_received(:info).with(
        hash_including(event: "job.completed", job_id: job.job_id, job_class: "PollEventSourceJob",
                       attempt: 1, sources_due: 1, sources_skipped: 0, run_ids: [ "run-1" ])
      )
    end

    # §7's rule is that a run row exists iff the process tried to reach GitHub. A source the
    # runner reloaded and found not-due after all opened no run, so it contributes no run id —
    # and it was not skipped either, which is a different fact.
    it "reports no run id for a source the runner found not due" do
      allow(runner).to receive(:call)
        .and_return(Github::IngestionRunner::Result.new(run_id: nil, status: "deferred",
                                                        deferral_reason: "cadence_due_at"))

      expect(poll!.outcome).to include(sources_due: 1, sources_skipped: 0, run_ids: [])
    end
  end

  # §2A: "The poller attempts once and exits if unavailable." A raise here would put a row in
  # solid_queue_failed_executions every minute a one-shot ran long — the system's own mutual
  # exclusion working is not a defect.
  describe "a source another process is already polling" do
    before do
      create_event_source(next_poll_at: nil)
      allow(runner).to receive(:call).and_raise(Github::Errors::SourceBusy)
    end

    it "reports the contention at INFO and completes the tick" do
      allow(Rails.logger).to receive(:info)

      job = described_class.new
      expect { job.perform_now }.not_to raise_error

      expect(Rails.logger).to have_received(:info)
        .with(hash_including(event: "ingestion.source_busy", job_id: job.job_id))
      expect(job.outcome).to include(sources_skipped: 1, run_ids: [])
    end

    # The guard against someone later adding retry_on and building a retry storm on top of a
    # 60-second recurring task.
    it "does not re-enqueue itself, because the next tick is 60 seconds away" do
      expect { poll! }.not_to have_enqueued_job
    end
  end

  describe "a source that fails" do
    let!(:failing) { create_event_source(next_poll_at: nil) }

    # By the time an error escapes the runner, the run row is finalized and the source's
    # backoff is written — so the remaining sources in this tick are still worth polling.
    it "logs the cycle and keeps going" do
      other = create_event_source(next_poll_at: nil)
      allow(Rails.logger).to receive(:error)
      allow(runner).to receive(:call).with(event_source: failing)
                                     .and_raise(Github::Errors::ConnectionFailed, "boom")
      allow(runner).to receive(:call).with(event_source: other).and_return(result)

      job = poll!

      expect(Rails.logger).to have_received(:error).with(
        hash_including(event: "ingestion.cycle_failed", event_source_id: failing.id,
                       error_class: "Github::Errors::ConnectionFailed", job_id: job.job_id)
      )
      expect(job.outcome).to include(sources_due: 2, sources_skipped: 1, run_ids: [ "run-1" ])
    end

    # A misconfiguration, a broken lock invariant or a dead connection is a fact about the
    # process. Continuing to the next source would only repeat it, and a tick that "completed"
    # after boot-level breakage would be a lie.
    it "lets a process-level failure fail the job" do
      allow(runner).to receive(:call).and_raise(Github::Errors::LockOrderViolation, "gate first")

      expect { poll! }.to raise_error(Github::Errors::LockOrderViolation)
    end

    it "logs the failure with the job id before letting it out" do
      allow(Rails.logger).to receive(:error)
      allow(runner).to receive(:call).and_raise(Github::Errors::LockOrderViolation, "gate first")

      job = described_class.new
      expect { job.perform_now }.to raise_error(Github::Errors::LockOrderViolation)

      expect(Rails.logger).to have_received(:error).with(
        hash_including(event: "job.failed", job_id: job.job_id,
                       error_class: "Github::Errors::LockOrderViolation")
      )
    end
  end

  # The tick and the real runner, over the offline corpus, so the two contracts are known to
  # fit: the scope hands over a source the runner accepts, and a real poll's work reaches the
  # queue.
  describe "with the real runner in fixture mode", type: :integration do
    before do
      allow(Github).to receive(:configuration).and_return(configuration_with("GITHUB_MODE" => "fixture"))

      # The outer stub has to come off first: #fixture_runner builds its runner through
      # Github::IngestionRunner.new, so with the double still in place it would hand back the
      # double and this group would assert nothing.
      allow(Github::IngestionRunner).to receive(:new).and_call_original
      real_runner = fixture_runner
      allow(Github::IngestionRunner).to receive(:new).and_return(real_runner)

      active_budget_window(now: frozen_time)
    end

    it "provisions, polls and persists the corpus page" do
      poll!

      expect(EventSource.sole.source_type).to eq("github_fixture_events")
      expect(PushEvent.count).to eq(4)
    end

    it "hands the run's enrichment work to the queue" do
      expect { poll! }.to have_enqueued_job(EnrichActorJob).exactly(:once)
        .and have_enqueued_job(EnrichRepositoryJob).exactly(:once)
    end
  end
end
