require "rails_helper"

# The only file in the suite that writes to github_push_ingestor_queue_test (§2A: "Ordinary
# specs use Active Job's test adapter; only dedicated queue integration tests touch the queue
# test database"). Everything here is what no double can prove: that an enqueue reaches a
# different database, that connects_to routes it there, and that the schema this PR ships is
# the schema Solid Queue expects.
RSpec.describe "Solid Queue", :queue do
  it "is the adapter these examples actually run against" do
    expect(ActiveJob::Base.queue_adapter).to be_a(ActiveJob::QueueAdapters::SolidQueueAdapter)
  end

  describe "enqueueing" do
    it "writes a job row and a ready execution" do
      expect { EnrichActorJob.perform_later }.to change(SolidQueue::Job, :count).by(1)

      job = SolidQueue::Job.last
      expect(job.class_name).to eq("EnrichActorJob")
      expect(job.queue_name).to eq("default")
      expect(SolidQueue::ReadyExecution.where(job_id: job.id)).to exist
    end

    it "round-trips a job's arguments" do
      ReconcilePendingEnrichmentsJob.perform_later

      expect(SolidQueue::Job.last.arguments.fetch("arguments")).to eq([])
    end

    # Ordering is random, so this example and the two above are an empirical check that
    # transactional fixtures really do roll back the *second* database's connection. If they
    # did not, whichever of these ran last would find the others' rows.
    it "leaves no rows behind for the next example" do
      expect(SolidQueue::Job.count).to eq(0)
    end
  end

  describe "the queue database" do
    it "routes Solid Queue's models to the queue connection, not the primary one" do
      expect(SolidQueue::Job.connection_db_config.name).to eq("queue")
      expect(SolidQueue::Job.connection_db_config.database).to eq("github_push_ingestor_queue_test")
    end

    it "is a different database from the one the business tables live in" do
      expect(SolidQueue::Job.connection_db_config.database)
        .not_to eq(ActiveRecord::Base.connection_db_config.database)
    end

    it "carries every table db/queue_migrate creates" do
      expect(SolidQueue::Job.connection.tables).to include(*QueueHelpers::SOLID_QUEUE_TABLES)
    end

    # The whole basis of §2A's "a second worker container cannot double-enqueue a tick", so it
    # is asserted rather than trusted to the gem.
    it "makes a recurring task's occurrence unique, which is what stops two schedulers racing" do
      index = SolidQueue::Job.connection.indexes("solid_queue_recurring_executions")
                             .find { |i| i.columns == %w[task_key run_at] }

      expect(index).not_to be_nil
      expect(index.unique).to be(true)
    end
  end

  # Solid Queue's own validator, over the real config/queue.yml and config/recurring.yml —
  # the same object `bin/jobs check` runs, so a schedule Fugit cannot parse or a task naming a
  # class that does not exist fails here rather than at 3am in a worker container.
  describe "the shipped configuration" do
    subject(:configuration) { SolidQueue::Configuration.new }

    it "is valid" do
      expect(configuration).to be_valid, -> { configuration.errors.full_messages.join("; ") }
    end

    it "configures the three processes the worker container runs" do
      expect(configuration.configured_processes.map(&:kind)).to contain_exactly(:dispatcher, :worker, :scheduler)
    end

    it "hands the scheduler this application's two ticks" do
      scheduler = configuration.configured_processes.find { |process| process.kind == :scheduler }

      expect(scheduler.attributes.fetch(:recurring_tasks).map(&:class_name))
        .to include("PollEventSourceJob", "ReconcilePendingEnrichmentsJob")
    end
  end
end
