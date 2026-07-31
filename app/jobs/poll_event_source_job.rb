# The recurring poll tick (IMPLEMENTATION_PLAN.md §2A): "Solid Queue recurring task fires
# every 60s → PollEventSourceJob computes effective_poll_time and no-ops unless a poll is
# due". config/recurring.yml is what fires it.
#
# **A tick is not a poll.** Against the default POLL_INTERVAL_SECONDS (300) roughly four
# ticks in five find nothing due, and those cost one indexed SELECT: EventSource.poll_due is
# a pre-filter, and a row it skips writes no ingestion_runs row, takes no lock, and spends no
# budget. The 60-second cadence exists so a source that becomes due at T is polled within a
# minute of T, not so that polls happen every minute — §10's allowance formula grants twelve
# poll requests an hour with zero headroom.
#
# The authority is still Github::IngestionRunner, which reloads the source *inside* its
# advisory lock before deciding. This job's scope only decides what is worth asking about.
#
# It takes no argument. §9's multi-source case is one row per source_type today, the request
# gate makes outbound concurrency exactly one application-wide, and Solid Queue concurrency
# limits keyed by source id (§9's third bullet) are deliberately not used: a semaphore has a
# fixed duration, so a container killed mid-poll would suppress that source until it expired,
# where the session advisory lock is released by PostgreSQL the moment the backend dies. PR 8
# is the PR about surviving container kills; a weaker duplicate of a lock we already hold
# would be a regression. Revisit in PR 11, where multi-poller tests could justify one.
class PollEventSourceJob < ApplicationJob
  # Facts about the process rather than about one source: continuing to the next source
  # would only repeat them, and a tick that "completed" after boot-level breakage would be a
  # lie. The same line Github::Ingestion::PageWriter::FATAL_ERRORS and
  # Github::Ingestion::OneShot::REFUSING_ERRORS draw.
  FATAL_ERRORS = [
    Github::Errors::ConfigurationError, Github::Errors::FixtureCorpusError,
    Github::Errors::LockOrderViolation, Github::Errors::ReentrantLock,
    Github::Errors::LockSessionChanged,
    ActiveRecord::ConnectionNotEstablished, ActiveRecord::ConnectionFailed
  ].freeze

  def perform
    now = Time.current
    # Nothing seeds event_sources — Github::Ingestion::SourceProvisioner's comment explains
    # why lazily-at-the-point-of-use is the only correct answer — so on a clean checkout this
    # is what makes the worker able to poll at all. Every call after the first is one SELECT.
    Github::Ingestion::SourceProvisioner.ensure!(now: now)

    sources = due_sources(now: now)
    results = sources.filter_map { |event_source| poll(event_source) }

    # run_ids rather than a count of results, because §7's rule is that a run row exists iff
    # the process tried to reach GitHub: a source the runner found not-due after all returns a
    # Result with no run_id, and counting it as a poll would say a request happened.
    # sources_skipped is the contention-and-failure half, which has no run row either but for
    # a reason an operator acts on.
    @outcome = { sources_due: sources.size, sources_skipped: sources.size - results.size,
                 run_ids: results.filter_map(&:run_id) }
  end

  private

  # Scoped to the current mode's source_type. A development database routinely holds both
  # rows — the README's reviewer path creates a github_fixture_events source — and a live
  # worker polling the fixture row would raise Errors::FixtureMiss once a minute forever.
  def due_sources(now:)
    source_type = Github::EventSources::Base.for_mode(Github.configuration.mode).source_type

    EventSource.poll_due(source_type: source_type, now: now).to_a
  end

  # @return [Github::IngestionRunner::Result, nil] nil when this source contributed no
  #   attempt — a busy source or one that failed in a way the tick can survive.
  def poll(event_source)
    Github::IngestionRunner.new.call(event_source: event_source)
  rescue *FATAL_ERRORS
    raise
  rescue Github::Errors::SourceBusy
    # §2A pins the poller's contract: "attempts once and exits if unavailable". §11 lists
    # "source lock acquired/busy" at INFO, and this stays INFO rather than becoming a failed
    # execution because the system's own mutual exclusion working is not a defect — a raise
    # here would put a row in solid_queue_failed_executions every minute a one-shot ran long.
    Rails.logger.info(event: "ingestion.source_busy", event_source_id: event_source.id, **log_context)
    nil
  rescue Github::Errors::FixtureMiss => error
    # A corpus gap is an authoring bug (§6 requires it raised rather than laundered), but it
    # is a fact about *this source's* scenario. Fixture mode is offline, so the tick reports
    # it and keeps going rather than failing every remaining source with it.
    cycle_failed(event_source, error)
  rescue StandardError => error
    # Already durable by the time this is reached: IngestionRunner finalizes the run row and
    # PollState writes the source's backoff before re-raising. One bad source must not
    # abandon the others in this tick.
    cycle_failed(event_source, error)
  end

  def cycle_failed(event_source, error)
    Rails.logger.error(event: "ingestion.cycle_failed", event_source_id: event_source.id,
                       error_class: error.class.name, error_message: error.message, **log_context)
    nil
  end
end
