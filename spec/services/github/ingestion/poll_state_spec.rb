require "rails_helper"

# §9's "Polling state": the ETag, the scheduling components, last successful poll time,
# and the consecutive-failure count. Budget state is global and is never written here.
RSpec.describe Github::Ingestion::PollState do
  let(:now) { frozen_time }
  let(:event_source) { create_event_source }
  let(:writer) do
    described_class.new(
      configuration: configuration_with,
      backoff: Github::PollBackoff.new(random: instance_double(Random, rand: 0.0)),
      clock: -> { now }
    )
  end

  def snapshot(poll_interval: 60, **overrides)
    headers = { "x-poll-interval" => poll_interval&.to_s, "x-ratelimit-resource" => "core" }.compact

    Github::RateLimitSnapshot.from_headers(headers.merge(overrides), observed_at: now)
  end

  def outcome(status:, **overrides)
    Github::Ingestion::PageLoop::Outcome.new(
      status: status, classification: overrides.delete(:classification) || :ok,
      snapshot: overrides.key?(:snapshot) ? overrides.delete(:snapshot) : snapshot, **overrides
    )
  end

  def record(outcome)
    writer.record!(event_source: event_source, outcome: outcome, now: now)
    event_source.reload
  end

  describe "a completed run" do
    before { record(outcome(status: "completed", etag: 'W/"abc"')) }

    # A fixed delay from the *end* of the run, not from its start. The allowance grants
    # ceil(3600 / POLL_INTERVAL_SECONDS) attempts an hour — twelve at the defaults, which
    # is exactly a fixed-rate schedule with zero headroom — so a drift-compensating
    # scheduler that fired early to make up for a slow run would be guaranteed a denial.
    it "schedules the next poll one cadence out" do
      expect(event_source.cadence_due_at).to eq(now + 300)
    end

    # X-Poll-Interval is a delta and §10 calls it "a floor, not a target", so it is stored
    # as an instant that self-expires and needs no clearing rule.
    it "records GitHub's own poll floor from the response" do
      expect(event_source.poll_floor_until).to eq(now + 60)
    end

    it "records the attempt, the success, and the ETag" do
      expect(event_source).to have_attributes(last_polled_at: now, last_success_at: now,
                                              etag: 'W/"abc"', status: "idle")
    end

    # Without the clearing rule a single stale hour-long backoff keeps deferring a source
    # that has been healthy for its last three polls — the component becomes permanent
    # rather than a constraint.
    it "clears the failure state it may have been carrying" do
      event_source.update!(consecutive_failures: 4, retry_not_before_at: now + 3600,
                           last_error: "boom")

      record(outcome(status: "completed"))

      expect(event_source).to have_attributes(consecutive_failures: 0, retry_not_before_at: nil,
                                              last_error: nil)
    end

    # §10's failed state clears on an operator's decision. IngestionRunner refuses to poll
    # a failed source at all, so this is unreachable in practice — and writing "idle" here
    # anyway would mean the gate being bypassed once silently returned the source to
    # service.
    it "does not return a failed source to service" do
      event_source.update!(status: "failed")

      record(outcome(status: "completed"))

      expect(event_source).to be_failed
    end

    it "caches the answer it just computed into next_poll_at" do
      expect(event_source.next_poll_at).to eq(now + 300)
    end
  end

  # §10 files a 304 under successful handling, ResponseClassifier.successful? includes it,
  # and IngestionRun::SUCCESSFUL_STATUSES already carries it: the poll succeeded and GitHub
  # reported nothing new. The attempt was spent, so the cadence moves.
  describe "a 304" do
    it "counts as a success and spends the cadence" do
      record(outcome(status: "not_modified", classification: :not_modified, etag: 'W/"same"'))

      expect(event_source).to have_attributes(
        last_success_at: now, cadence_due_at: now + 300, consecutive_failures: 0, etag: 'W/"same"'
      )
    end
  end

  describe "a failed run" do
    let!(:recorded) { record(outcome(status: "failed", classification: :server_error, last_error: "boom")) }

    it "counts the failure and backs the source off" do
      expect(event_source).to have_attributes(consecutive_failures: 1, last_error: "boom",
                                              retry_not_before_at: now + 60, last_success_at: nil)
    end

    it "still spends the cadence, because the attempt reached GitHub" do
      expect(event_source.cadence_due_at).to eq(now + 300)
    end

    it "lengthens the backoff as failures accumulate" do
      record(outcome(status: "failed", classification: :server_error, last_error: "boom"))

      expect(event_source).to have_attributes(consecutive_failures: 2, retry_not_before_at: now + 120)
    end
  end

  # §10: "/events returns permanent 4xx → source failed/disabled". Terminal on first
  # occurrence and operator-recoverable only, so there is no counter worth raising and
  # nothing to back off from. `enabled` is left alone — that column means an operator
  # turned this off, and two representations of "off" is the drift trap.
  describe "a permanent client error on /events" do
    it "takes the source out of service on the first occurrence, without touching enabled" do
      record(outcome(status: "failed", classification: :not_found, last_error: "gone",
                     source_failing: true))

      expect(event_source).to have_attributes(status: "failed", enabled: true,
                                              consecutive_failures: 0, retry_not_before_at: nil,
                                              last_error: "gone")
    end
  end

  # §10: a budget denial and a held gate mean the request never happened. Letting either
  # advance the cadence would convert contention into lost captures, and letting either
  # count as a failure would burn a healthy source's backoff.
  describe "a deferral that never reached GitHub" do
    %i[ budget_denied gate_unavailable ].each do |classification|
      it "leaves every scheduling component untouched for #{classification}" do
        event_source.update!(cadence_due_at: now + 120, consecutive_failures: 2)

        record(outcome(status: "deferred", classification: classification,
                       deferral_reason: classification.to_s, snapshot: nil))

        expect(event_source).to have_attributes(
          cadence_due_at: now + 120, last_polled_at: nil, last_success_at: nil,
          consecutive_failures: 2, etag: nil
        )
      end
    end

    it "still refreshes the cached answer, so the operator line has an instant to print" do
      event_source.update!(cadence_due_at: now + 120)

      record(outcome(status: "deferred", classification: :budget_denied, snapshot: nil))

      expect(event_source.next_poll_at).to eq(now + 120)
    end
  end

  # GitHub answered, so the attempt is spent and the cadence moves — but §10 is explicit
  # that a rate limit is not a failure, so the failure count and last_error stay put.
  describe "a rate-limited response" do
    it "spends the cadence without counting a failure" do
      event_source.update!(consecutive_failures: 3)

      record(outcome(status: "deferred", classification: :rate_limited,
                     deferral_reason: "rate_limited"))

      expect(event_source).to have_attributes(cadence_due_at: now + 300, last_polled_at: now,
                                              consecutive_failures: 3, last_success_at: nil)
    end

    # §10: "also update the request-specific source or entity retry state". Not redundant
    # with the global block: ROLL_WINDOW_SQL clears that at the window boundary, while this
    # component survives it, so a secondary limit that outlives a rollover still defers the
    # source that provoked it.
    it "records the secondary limit's own instant against the source" do
      decision = Github::RateLimitPolicy::Decision.new(
        kind: :secondary_rate_limit, blocked_until: now + 300,
        source_retry_at: now + 300, window_status: nil
      )

      record(outcome(status: "deferred", classification: :secondary_limited, decision: decision))

      expect(event_source.retry_not_before_at).to eq(now + 300)
    end
  end

  describe "the cached next_poll_at" do
    # Computed last, from the values this run is about to commit plus a ledger row that
    # already carries any block the rate-limit policy wrote while the pages were walked.
    it "reflects a global block written moments earlier, not just this run's cadence" do
      active_budget_window(now: now)
      current_budget.update!(global_blocked_until: now + 1800)

      record(outcome(status: "completed"))

      expect(event_source.next_poll_at).to eq(now + 1800)
    end

    it "takes the latest of the components, so the server floor can win a short cadence" do
      writer_with_short_cadence = described_class.new(
        configuration: configuration_with("POLL_INTERVAL_SECONDS" => "30"), clock: -> { now }
      )

      writer_with_short_cadence.record!(event_source: event_source, now: now,
                                        outcome: outcome(status: "completed", snapshot: snapshot(poll_interval: 600)))

      expect(event_source.reload.next_poll_at).to eq(now + 600)
    end
  end

  describe "a response with no X-Poll-Interval" do
    it "leaves the floor alone rather than writing the instant it was polled" do
      record(outcome(status: "completed", snapshot: snapshot(poll_interval: nil)))

      expect(event_source.poll_floor_until).to be_nil
    end
  end
end
