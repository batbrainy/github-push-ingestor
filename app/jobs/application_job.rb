# The base every job in this application inherits (IMPLEMENTATION_PLAN.md §5, §11).
#
# Two things live here and nothing else: the enqueue-after-commit contract, and the job half
# of §11's common log fields — "timestamp, level, service, environment, event name, run_id,
# job ID, ...". Story 4 asks for job IDs in the logs, and this is where they enter the
# stream, once, for every job.
#
# **No retry_on, deliberately, anywhere in this application.** Every job here can spend
# GitHub request budget, and both retry ladders already exist and are durable:
# Github::Ingestion::PollState writes consecutive_failures + retry_not_before_at for a
# source, and Github::Enrichment::EntityState writes next_retry_at for an entity. A second,
# uncoordinated Active Job ladder would re-poll a source whose backoff was just written and
# spend the hourly allowance twice on the same failure. The 60-second recurring tick is the
# retry — an escaped exception is a defect, so it fails the execution, job.failed says why,
# and the next tick starts from committed state.
#
# No discard_on ActiveJob::DeserializationError either: no job here takes a record argument.
class ApplicationJob < ActiveJob::Base
  # §2A's enqueue semantics, stated on the class a reader of a job actually opens. Solid
  # Queue runs in its own database, so an enqueue can never join the business transaction;
  # this makes the boundary explicit rather than incidental, and it holds even for a future
  # caller that enqueues from inside a transaction the way this application's call sites
  # deliberately do not.
  self.enqueue_after_transaction_commit = true

  around_perform do |job, block|
    started = job.monotonic_now
    Rails.logger.debug(event: "job.started", **job.log_context)

    block.call

    Rails.logger.info(event: "job.completed", **job.log_context,
                      duration_ms: job.elapsed_ms(started), **job.outcome)
  rescue StandardError => error
    # Logged and re-raised: Solid Queue has to see the failure to record it, and §11 wants
    # the reason in the same stream as everything else rather than only in
    # solid_queue_failed_executions.
    Rails.logger.error(event: "job.failed", **job.log_context, duration_ms: job.elapsed_ms(started),
                       error_class: error.class.name, error_message: error.message)
    raise
  end

  # §11's common fields for a job. `attempt` is Active Job's own execution counter, which it
  # increments in perform_now *before* these callbacks run — so it already reads 1 on a first
  # delivery and 2 on a redelivery after a crash, which is the at-least-once behaviour §8
  # describes, made visible.
  def log_context
    { job_id: job_id, job_class: self.class.name, queue: queue_name, attempt: executions }
  end

  # Identifiers a job wants on its completion line, so a reviewer's trace is one hop:
  # job_id → run_id → every ingestion.* line, all of which already carry run_id. A job sets
  # @outcome; one that does not simply reports nothing extra.
  def outcome
    @outcome.to_h
  end

  def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def elapsed_ms(started) = ((monotonic_now - started) * 1000).round(1)
end
