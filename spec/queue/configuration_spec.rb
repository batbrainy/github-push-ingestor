require "rails_helper"

# config/queue.yml and config/recurring.yml decide whether this system runs at all, and a
# mistyped key in either is silent: the supervisor starts, the tick never fires, and nothing
# in the suite would notice. The same argument spec/docker_compose_spec.rb makes about a
# profile key, applied to the two files PR 8 adds.
#
# No database and no adapter swap here — this is the YAML and the constants. The real
# validator runs in spec/queue/solid_queue_integration_spec.rb, where a queue connection is
# already open.
RSpec.describe "Solid Queue configuration" do
  let(:queue_config) { YAML.safe_load(Rails.root.join("config/queue.yml").read, aliases: true) }
  let(:recurring) { YAML.safe_load(Rails.root.join("config/recurring.yml").read, aliases: true) }

  ENVIRONMENTS = %w[development test production].freeze

  describe "config/recurring.yml" do
    # Development is what `docker compose up` runs and what a reviewer watches; test is what
    # CI's supervisor smoke boots. A task defined only in production would mean neither ever
    # proved the tick fires.
    it "defines the same tasks in every environment" do
      task_sets = ENVIRONMENTS.map { |environment| recurring.fetch(environment).keys.sort }

      expect(task_sets.uniq.size).to eq(1)
      expect(task_sets.first)
        .to contain_exactly("clear_solid_queue_finished_jobs", "poll_event_sources",
                            "reconcile_pending_enrichments")
    end

    it "schedules a job class this application actually defines" do
      classes = recurring.fetch("production").values.filter_map { |task| task["class"] }

      expect(classes).to contain_exactly("PollEventSourceJob", "ReconcilePendingEnrichmentsJob")
      expect(classes.map(&:constantize)).to all(be < ApplicationJob)
    end

    # §2A: "Solid Queue recurring task fires every 60s". A 300-second tick would be the
    # cadence twice over, and a source that became due at T would wait up to five minutes past
    # it; a 1-second tick would spend the poll allowance on SELECTs of an unchanged table.
    it "ticks every 60 seconds, for the poll and the reconciler alike" do
      %w[poll_event_sources reconcile_pending_enrichments].each do |task|
        expect(recurring.dig("production", task, "schedule")).to eq("every 60 seconds")
      end
    end

    # Solid Queue's recurring uniqueness guarantee — the unique index on (task_key, run_at) —
    # holds "as long as you keep the jobs around", so preserve_finished_jobs stays at its
    # default and the installer's hourly cleanup is what bounds the table instead.
    it "keeps the installer's finished-job cleanup, which is what makes retention safe" do
      expect(recurring.dig("production", "clear_solid_queue_finished_jobs", "command"))
        .to include("clear_finished_in_batches")
    end
  end

  describe "config/queue.yml" do
    it "configures a dispatcher and a worker in every environment" do
      ENVIRONMENTS.each do |environment|
        expect(queue_config.dig(environment, "workers")).to be_present
        expect(queue_config.dig(environment, "dispatchers")).to be_present
      end
    end

    # A job enqueued into a queue no worker polls is a silent, total failure, and nothing else
    # in the suite would catch it. Every job here uses the default queue, so one worker on "*"
    # is the whole guarantee.
    it "works every queue this application enqueues into" do
      # Through an instance: Active Job's default queue name is a lambda until a job resolves
      # it.
      queues = [ PollEventSourceJob, EnrichActorJob, EnrichRepositoryJob,
                 ReconcilePendingEnrichmentsJob ].map { _1.new.queue_name }.uniq

      expect(queues).to eq([ "default" ])
      expect(queue_config.dig("production", "workers").map { _1["queues"] }).to all(eq("*"))
    end

    # §5's request gate makes outbound concurrency exactly one application-wide, so extra
    # threads could only queue behind it while holding a primary-database connection for up to
    # Github::RequestGate::WAIT_SECONDS. config/database.yml grants RAILS_MAX_THREADS (5) per
    # database, and the worker holds both.
    it "keeps the thread pool inside the connection pool the worker is granted" do
      threads = queue_config.dig("production", "workers").sum { _1.fetch("threads") }

      expect(threads).to be <= Integer(ENV.fetch("RAILS_MAX_THREADS", 5))
      expect(threads).to be >= 2
    end
  end

  describe "bin/jobs" do
    let(:path) { Rails.root.join("bin/jobs") }

    it "exists and is executable, because the worker service runs it directly" do
      expect(path).to be_file
      expect(path).to be_executable
    end

    # config/environment rather than config/boot: config/initializers/github.rb validates the
    # budget configuration in to_prepare, so a worker that would over-commit the hourly
    # allowance stops at boot instead of polling into it.
    it "boots the full application, so startup validation reaches the worker" do
      expect(path.read).to include('require_relative "../config/environment"')
    end
  end
end
