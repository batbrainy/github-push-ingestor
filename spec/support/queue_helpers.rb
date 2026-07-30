# Active Job's adapter policy for the suite (IMPLEMENTATION_PLAN.md §2A: "Ordinary specs use
# Active Job's test adapter; only dedicated queue integration tests touch the queue test
# database").
#
# config/environments/test.rb sets the test adapter, so the default needs no help here. What
# this file adds is the exception — the handful of examples tagged :queue, which swap in the
# real Solid Queue adapter to prove the parts no double can: that an enqueue reaches the
# queue *database*, that connects_to routes it there, and that the schema is loaded.
module QueueHelpers
  # Every table db/queue_migrate creates, jobs last so the foreign keys unwind in order.
  SOLID_QUEUE_TABLES = %w[
    solid_queue_blocked_executions solid_queue_claimed_executions solid_queue_failed_executions
    solid_queue_ready_executions solid_queue_recurring_executions solid_queue_scheduled_executions
    solid_queue_pauses solid_queue_processes solid_queue_recurring_tasks solid_queue_semaphores
    solid_queue_jobs
  ].freeze
end

RSpec.configure do |config|
  # ActiveJob::TestHelper forces the test adapter in before_setup — a prepend_before, so it
  # runs *inside* the around hook below and would silently undo the swap. Deriving the
  # include from metadata is what keeps the two policies from fighting; spec/job_boundary_spec.rb
  # asserts the split holds.
  config.define_derived_metadata do |metadata|
    metadata[:active_job_test_adapter] = true unless metadata[:queue]
  end

  config.include ActiveJob::TestHelper, :active_job_test_adapter

  config.around(:each, :queue) do |example|
    previous = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :solid_queue

    begin
      example.run
    ensure
      ActiveJob::Base.queue_adapter = previous
    end
  end

  # Two jobs at once: it clears rows a crashed run — or CI's `bin/jobs` supervisor smoke,
  # which runs against RAILS_ENV=test — committed where no example transaction will ever roll
  # them back, and it turns a queue test database that was never prepared into one actionable
  # sentence instead of a PG::UndefinedTable inside whichever :queue example ran first.
  #
  # before(:suite), because this is the only point at which no fixture transaction is open.
  config.before(:suite) do
    SolidQueue::Job.connection.truncate_tables(*QueueHelpers::SOLID_QUEUE_TABLES)
  rescue ActiveRecord::StatementInvalid => error
    abort <<~MESSAGE
      The queue test database is not prepared: #{error.message.lines.first&.strip}

      Run `bin/rails db:test:prepare` (the `test` compose service and CI both do).
    MESSAGE
  end
end
