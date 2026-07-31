require "rails_helper"

# The job half of §11's common fields, and §2A's enqueue-after-commit contract. Both are
# properties every job in this application inherits, so they are asserted once, here, against
# a job defined for the purpose rather than against whichever real job happens to be handy.
RSpec.describe ApplicationJob do
  # Named, not anonymous: Active Job serializes the class name, so an anonymous class cannot
  # be enqueued and half of these examples would be untestable.
  before do
    stub_const("SpecProbeJob", Class.new(ApplicationJob) do
      def self.name = "SpecProbeJob"

      cattr_accessor :behaviour, default: -> { }

      def perform
        @outcome = { probe: "ran" }
        self.class.behaviour.call
      end
    end)
  end

  describe "the lines every job emits" do
    before { allow(Rails.logger).to receive(:info).and_call_original }

    it "reports the job id, class, queue and attempt on completion" do
      job = SpecProbeJob.new
      job.perform_now

      expect(Rails.logger).to have_received(:info).with(
        hash_including(event: "job.completed", job_id: job.job_id, job_class: "SpecProbeJob",
                       queue: "default", attempt: 1, probe: "ran")
      )
    end

    it "measures how long the job took" do
      allow(Rails.logger).to receive(:info)

      SpecProbeJob.new.perform_now

      expect(Rails.logger).to have_received(:info)
        .with(hash_including(event: "job.completed", duration_ms: an_instance_of(Float)))
    end

    # §8's at-least-once execution, made visible: a redelivery after a crash is the same job
    # id at a higher attempt, which is how an operator tells one from a fresh tick.
    it "counts a redelivery as a later attempt of the same job" do
      allow(Rails.logger).to receive(:info)
      job = SpecProbeJob.new

      job.perform_now
      job.perform_now

      expect(Rails.logger).to have_received(:info)
        .with(hash_including(event: "job.completed", job_id: job.job_id, attempt: 2))
    end

    # Logged *and* re-raised: Solid Queue has to see the failure to record it, and §11 wants
    # the reason in the same stream as everything else rather than only in
    # solid_queue_failed_executions.
    it "reports a failure with its cause and lets it out" do
      allow(Rails.logger).to receive(:error)
      SpecProbeJob.behaviour = -> { raise Github::Errors::MalformedResponse, "not an array" }

      job = SpecProbeJob.new
      expect { job.perform_now }.to raise_error(Github::Errors::MalformedResponse)

      expect(Rails.logger).to have_received(:error).with(
        hash_including(event: "job.failed", job_id: job.job_id,
                       error_class: "Github::Errors::MalformedResponse", error_message: "not an array")
      )
    end
  end

  describe "retries" do
    # Every job here can spend GitHub budget, and both retry ladders are already durable and
    # coordinated with the ledger (Github::Ingestion::PollState and
    # Github::Enrichment::EntityState). A second, uncoordinated Active Job ladder would
    # re-poll a source whose backoff was just written. The 60-second recurring tick is the
    # retry.
    it "declares none, in any job in this application" do
      jobs = [ ApplicationJob, PollEventSourceJob, EnrichActorJob, EnrichRepositoryJob,
               ReconcilePendingEnrichmentsJob ]

      expect(jobs.map { |job| job.rescue_handlers.map(&:first) }.flatten).to be_empty
    end
  end

  describe "enqueue semantics (§2A)" do
    it "defers an enqueue until the enclosing transaction commits" do
      expect(described_class.enqueue_after_transaction_commit).to be(true)
    end

    # The property that setting buys, rather than the setting alone. The example's fixture
    # transaction is non-joinable, so this is a genuine inner transaction — the same
    # distinction Github::IngestionRunner's "no application transaction across a fetch"
    # example relies on.
    it "enqueues nothing until the transaction has committed" do
      enqueued_at_the_time = nil

      ActiveRecord::Base.transaction do
        SpecProbeJob.perform_later
        enqueued_at_the_time = ActiveJob::Base.queue_adapter.enqueued_jobs.size
      end

      expect(enqueued_at_the_time).to eq(0)
      expect(ActiveJob::Base.queue_adapter.enqueued_jobs.size).to eq(1)
    end

    it "still enqueues when no transaction is open" do
      expect { SpecProbeJob.perform_later }.to have_enqueued_job(SpecProbeJob)
    end
  end
end
