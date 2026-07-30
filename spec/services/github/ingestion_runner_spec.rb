require "rails_helper"

RSpec.describe Github::IngestionRunner do
  let(:event_source) { fixture_event_source }

  before { active_budget_window(now: frozen_time) }

  def ingest(runner = fixture_runner, **options)
    runner.call(event_source: event_source, **options)
  end

  # §12's "Public-event response ingestion", "Non-push events ignored and counted" and
  # "Malformed events quarantined per taxonomy without terminating the batch", over the real
  # corpus page, in one group. Every number here is derived in
  # fixtures/github/bodies/events/page-1.json: three well-formed pushes, one WatchEvent, one
  # push with no head, one with an unusable head, one envelope with no type, one more
  # well-formed push.
  describe "ingesting the corpus page" do
    let!(:result) { ingest }

    it "completes the run and records the page" do
      expect(result).to be_completed
      expect(result.run_id).to be_present
      expect(result.tally.pages_fetched).to eq(1)
      expect(result.last_error).to be_nil
    end

    it "reports the counters §11 asks for" do
      expect(result.tally.to_h).to eq(
        pages_fetched: 1, events_received: 8, push_events_seen: 6, events_created: 4,
        duplicates_skipped: 0, events_quarantined: 3, events_ignored: 1, events_failed: 0
      )
    end

    it "persists the four well-formed push events and nothing else" do
      expect(PushEvent.pluck(:github_event_id))
        .to match_array(%w[58000000001 58000000002 58000000003 58000000008])
    end

    # §8 quarantines at step 5 and upserts stubs at step 6, so only envelopes that normalized
    # produce entities. Independent confirmation that this is the intended reading: the
    # corpus's enrichment fixtures are exactly these three users and three repositories.
    it "upserts a stub for every entity a persisted event referenced, and no others" do
      expect(GithubActor.pluck(:github_id)).to match_array([ 583_231, 1_024_025, 7_700_421 ])
      expect(GithubRepository.pluck(:github_id)).to match_array([ 1_296_269, 1_300_192, 1_490_033 ])
      expect(GithubActor.pluck(:enrichment_status).uniq).to eq([ "pending" ])
    end

    it "quarantines the three malformed envelopes under distinct classifications" do
      expect(QuarantinedEvent.pluck(:github_event_id, :error_code)).to match_array([
        [ "58000000005", "missing_required_field" ],
        [ "58000000006", "invalid_field_format" ],
        [ "58000000007", "missing_event_type" ]
      ])
    end

    it "records activity from the observation and the event's own timestamp independently" do
      expect(GithubActor.find_by(github_id: 583_231)).to have_attributes(
        first_seen_at: frozen_time, last_seen_at: frozen_time,
        latest_event_at: Time.utc(2026, 7, 29, 11, 59, 2)
      )
    end

    # GitHub's clock is not ours, and the documented 30s–6h latency means occurred_at can sit
    # either side of the observation. Nothing may clamp it.
    it "lets an event newer than the observation keep its own timestamp" do
      expect(GithubRepository.find_by(github_id: 1_490_033).latest_event_at)
        .to eq(Time.utc(2026, 7, 29, 12, 0, 41))
    end

    it "writes one finished run row carrying the same counters" do
      run = IngestionRun.sole

      expect(run).to be_completed
      expect(run.run_id).to eq(result.run_id)
      expect(run.completed_at).to eq(frozen_time)
      expect(run).to have_attributes(result.tally.persistable_attributes)
    end

    # §12: "304 Not Modified (processing skipped, quota debited)" — and the same accounting
    # applies to a 200. One page fetched is one poll attempt spent.
    it "spends exactly one poll attempt" do
      expect(current_budget.poll_used).to eq(1)
    end
  end

  # §12: "Duplicate poll results (fixture replay) — duplicates skipped and no entity
  # reactivation occurs." A second transport instance restarts the scripted sequence, which
  # is a faithful model of a second one-shot process.
  describe "replaying the same page" do
    # Past the 300-second cadence the first run wrote, so the replay is genuinely due
    # rather than deferred. §12's "duplicate poll results (fixture replay)" is about the
    # write path absorbing duplicates, so the schedule must not be what stops it.
    let(:later) { frozen_time + 301 }

    before do
      ingest

      # updated_at is held at the frozen instant deliberately: IDENTITY_MERGE gates each
      # assignment on EXCLUDED.updated_at >= the stored value, so a wall-clock touch here
      # would block the refresh and the example would pass for the wrong reason.
      GithubActor.where(github_id: 583_231)
                 .update_all(login: "stale-login", enrichment_status: "skipped_budget",
                             skipped_at: frozen_time, updated_at: frozen_time)
    end

    let!(:replay) { ingest(fixture_runner(transport: fixture_transport, now: later)) }

    it "absorbs every duplicate and creates nothing" do
      expect(replay.tally.to_h).to include(events_created: 0, duplicates_skipped: 4,
                                           events_quarantined: 3, push_events_seen: 6)
      expect(PushEvent.count).to eq(4)
    end

    # §7 merge rule 1: identity refreshes "on any observation, including duplicates".
    it "still refreshes identity fields from the envelope" do
      expect(GithubActor.find_by(github_id: 583_231).login).to eq("octocat")
    end

    # §7 merge rules 3 and 4, and Appendix D item 5's reason for the gate.
    it "registers no new activity and cannot reactivate a budget-skipped entity" do
      expect(GithubActor.find_by(github_id: 583_231)).to have_attributes(
        last_seen_at: frozen_time, enrichment_status: "skipped_budget", skipped_at: frozen_time
      )
    end

    # §7's occurrence-count upsert: the rows are the same three, observed twice.
    it "counts the malformed envelopes again without adding rows" do
      expect(QuarantinedEvent.count).to eq(3)
      expect(QuarantinedEvent.pluck(:occurrence_count)).to all(eq(2))
      expect(QuarantinedEvent.pluck(:first_received_at)).to all(eq(frozen_time))
      expect(QuarantinedEvent.pluck(:last_received_at)).to all(eq(later))
    end

    it "leaves the entity population unchanged" do
      expect(GithubActor.count).to eq(3)
      expect(GithubRepository.count).to eq(3)
    end
  end

  # The default scenario's second scripted response is a 304 with the same ETag, so a single
  # transport reaching for page one twice models a long-lived process.
  #
  # The second call is one cadence later rather than forced: §9 makes --force omit the
  # stored ETag, so a forced second poll would send no If-None-Match and the conditional
  # request this group exists to prove would never happen.
  describe "a 304 from GitHub" do
    let(:transport) { fixture_transport }
    let(:later) { frozen_time + 301 }

    let!(:result) do
      fixture_runner(transport: transport).call(event_source: event_source)
      fixture_runner(transport: transport, now: later).call(event_source: event_source)
    end

    it "records the run as not modified rather than as a failure" do
      expect(result).to be_not_modified
      expect(result.last_error).to be_nil
      expect(IngestionRun.order(:id).last).to be_not_modified
    end

    it "processes nothing" do
      expect(result.tally.to_h.values).to all(eq(0))
      expect(PushEvent.count).to eq(4)
      expect(QuarantinedEvent.pluck(:occurrence_count)).to all(eq(1))
    end

    # §12 and Appendix A item 1: an unauthenticated 304 consumes quota. Two attempts, two
    # debits.
    it "still spends the poll attempt" do
      expect(current_budget.poll_used).to eq(2)
    end

    # §9 scopes the persisted ETag to the canonical first-page request. The corpus scripts
    # its responses positionally rather than by matching If-None-Match, so the corpus can
    # never prove the conditional request happened — only the transport's recorded requests
    # can, which is why the assertion is made there.
    it "sends the ETag the first poll stored, so this 304 is ours and not the script's" do
      etag = 'W/"3f2a1c9d0b7e4a58c1d2e3f4a5b6c7d8"'

      expect(transport.requests.map { |request| request[:headers]["if-none-match"] })
        .to eq([ nil, etag ])
      expect(event_source.reload.etag).to eq(etag)
    end

    # §10 files a 304 under successful handling: the poll succeeded and GitHub reported
    # nothing new, so the source is demonstrably healthy and the spent attempt moves the
    # cadence on.
    it "counts as a healthy poll and schedules the next one" do
      expect(event_source.reload).to have_attributes(
        last_success_at: later, cadence_due_at: later + 300, consecutive_failures: 0
      )
    end
  end

  describe "an empty page" do
    it "completes the run, and counts the page even though it carried nothing" do
      result = ingest(fixture_runner(executor: fixture_executor(transport: empty_page_transport)))

      expect(result).to be_completed
      expect(result.tally.to_h).to include(pages_fetched: 1, events_received: 0, events_created: 0)
      expect(IngestionRun.sole).to be_completed
    end
  end

  # §10: a budget denial and a busy gate "never happened" — so they are deferrals, not
  # failures, and must not burn a healthy source's failure count.
  #
  # An exhausted poll class is caught *before* the request now, because §9 lists
  # poll_class_blocked_until among the scheduling components. That is strictly better than
  # discovering it at the reservation: no lock work, no run row, no log line per tick. The
  # ledger's denial path stays live for everything the schedule cannot see coming — a
  # co-tenant spending the shared budget, a reserve breach, a class that runs out partway
  # through a multi-page walk.
  describe "an exhausted poll allowance" do
    let(:transport) { fixture_transport }

    let!(:result) do
      active_budget_window(now: frozen_time, poll_used: 12, poll_allowance: 12)
      ingest(fixture_runner(transport: transport))
    end

    it "defers before asking, naming the component that holds the poll back" do
      expect(result).to be_deferred
      expect(result.deferral_reason).to eq("poll_class_blocked_until")
      expect(result.next_poll_at).to eq(current_budget.reset_at)
    end

    # A run row records a poll attempt, and no attempt was made — §7 calls the row "one
    # polling cycle", and none happened.
    it "opens no run row, because nothing tried to reach GitHub" do
      expect(IngestionRun.count).to eq(0)
      expect(result.run_id).to be_nil
    end

    it "spends nothing and writes no events" do
      expect(transport.requests).to be_empty
      expect(PushEvent.count).to eq(0)
      expect(current_budget.poll_used).to eq(12)
    end

    it "leaves the source's own scheduling state exactly as it was" do
      expect(event_source.reload).to have_attributes(last_polled_at: nil, cadence_due_at: nil,
                                                     consecutive_failures: 0)
    end
  end

  # The ledger's own denial, reached when the schedule could not have known: GitHub's
  # `remaining` has fallen to the reserve because something else behind this IP spent it.
  describe "a budget denial from the ledger" do
    let(:transport) { fixture_transport }

    let!(:result) do
      active_budget_window(now: frozen_time, remaining: 8, reserve: 8)
      ingest(fixture_runner(transport: transport))
    end

    it "defers the run and names the denial condition" do
      expect(result).to be_deferred
      expect(result.deferral_reason).to eq("reserve_reached")
      expect(IngestionRun.sole).to be_deferred
    end

    it "spends nothing and leaves the cadence alone, because the request never happened" do
      expect(transport.requests).to be_empty
      expect(current_budget.poll_used).to eq(0)
      expect(event_source.reload).to have_attributes(cadence_due_at: nil, consecutive_failures: 0)
    end

    # §10 lists "usable budget has reached the global reserve" among the three conditions
    # that stop *every* live request, so the denial does not merely fail this attempt — it
    # records a block, and the next attempt is turned away before it asks.
    it "blocks every live request until the window resets" do
      expect(current_budget.global_blocked_until).to eq(current_budget.reset_at)

      again = ingest(fixture_runner(transport: fixture_transport, now: frozen_time + 600))

      expect(again.deferral_reason).to eq("global_blocked_until")
      expect(IngestionRun.count).to eq(1)
    end
  end

  # §11 makes run_id the correlation identifier for the whole flow, and a deferral is
  # exactly the line an operator greps for when a run produced no events — so it must not
  # be the one ingestion line that cannot be joined to its run.
  describe "the deferral log line" do
    it "carries the run_id of the run it belongs to" do
      allow(Rails.logger).to receive(:info)
      active_budget_window(now: frozen_time, remaining: 8, reserve: 8)

      deferred = ingest(fixture_runner(transport: fixture_transport))

      expect(Rails.logger).to have_received(:info).with(
        hash_including(event: "ingestion.deferred", run_id: deferred.run_id,
                       reason: "reserve_reached")
      )
    end

    # A pre-flight deferral has no run to belong to, so it reports the source instead. The
    # asymmetry is deliberate and is the observable half of "a run row exists iff the
    # process tried to reach GitHub".
    it "reports the source, not a run, when the poll was never attempted" do
      allow(Rails.logger).to receive(:info)
      ingest
      ingest(fixture_runner(now: frozen_time + 60))

      expect(Rails.logger).to have_received(:info).with(
        hash_including(event: "ingestion.not_due", event_source_id: event_source.id,
                       deferral_reason: :cadence_due_at)
      )
    end
  end

  describe "a busy request gate" do
    it "defers without spending anything" do
      transport = fixture_transport

      # 0.1s, not 0: PostgreSQL reads lock_timeout = 0 as "no timeout", so a zero wait
      # would block forever rather than defer. The executor's own spec uses the same value.
      result = other_session_holding(Github::AdvisoryLock::REQUEST_GATE_NAMESPACE,
                                     Github::AdvisoryLock::REQUEST_GATE_KEY) do
        ingest(fixture_runner(transport: transport, request_gate_wait: 0.1))
      end

      expect(result).to be_deferred
      expect(result.deferral_reason).to eq("gate_unavailable")
      expect(transport.requests).to be_empty
      expect(current_budget.poll_used).to eq(0)
    end
  end

  describe "GitHub declining to serve the request" do
    it "defers a primary rate limit rather than recording a failure" do
      result = ingest(fixture_runner(transport: fixture_transport(scenario: "rate_limited")))

      expect(result).to be_deferred
      expect(result.classification).to eq(:rate_limited)
      expect(IngestionRun.sole).to be_deferred
    end

    it "defers a secondary rate limit the same way" do
      result = ingest(fixture_runner(transport: fixture_transport(scenario: "secondary_rate_limited")))

      expect(result).to be_deferred
      expect(result.classification).to eq(:secondary_limited)
    end

    it "fails a server error that outlived its retries, and says what happened" do
      result = ingest(fixture_runner(transport: fixture_transport(scenario: "transient_failure_exhausted")))

      expect(result).to be_failed
      expect(result.last_error).to eq("GitHub returned 500 (server_error)")
      expect(IngestionRun.sole.last_error).to eq("GitHub returned 500 (server_error)")
    end
  end

  # §10 makes every retry its own reservation "through the same gate and ledger", so the
  # ledger is where the retries are visible — and the page must be processed exactly once.
  it "processes a page recovered by retries exactly once" do
    result = ingest(fixture_runner(transport: fixture_transport(scenario: "transient_failure")))

    expect(result).to be_completed
    expect(result.tally.events_created).to eq(4)
    expect(current_budget.poll_used).to eq(3)
  end

  # §7's taxonomy row 5: "Entire HTTP response body is invalid JSON — Ingestion/request
  # failure, not an individual quarantined event."
  describe "a response body that is not a JSON array" do
    let!(:result) { ingest(fixture_runner(executor: fixture_executor(transport: object_body_transport))) }

    it "fails the run" do
      expect(result).to be_failed
      expect(result.last_error).to include("Github::Errors::MalformedResponse")
      expect(IngestionRun.sole).to be_failed
    end

    it "quarantines nothing, because nothing in it identifies an event" do
      expect(QuarantinedEvent.count).to eq(0)
      expect(result.tally.pages_fetched).to eq(0)
    end
  end

  # §9: "Multiple poller or worker containers must not cause the same source to be polled
  # concurrently."
  describe "a source another process already owns" do
    it "raises rather than polling, and leaves no trace at all" do
      transport = fixture_transport
      runner = fixture_runner(transport: transport)

      other_session_holding(Github::AdvisoryLock::SOURCE_LOCK_NAMESPACE,
                            Github::AdvisoryLock.key_for(event_source.id)) do
        expect { runner.call(event_source: event_source) }.to raise_error(Github::Errors::SourceBusy)
      end

      # The run row is opened inside the lock, which is what makes this provable rather than
      # merely likely.
      expect(IngestionRun.count).to eq(0)
      expect(transport.requests).to be_empty
      expect(current_budget.poll_used).to eq(0)
    end
  end

  # BudgetLedger#assert_committable! already forbids this, but only for the ledger's own
  # statement. This asserts the property the whole design rests on: at the moment the
  # transport is called, no application transaction is open. A future refactor that wrapped
  # the run in one would otherwise fail only in production, where the example transaction
  # does not mask it.
  #
  # Collected over every fetch of a multi-page walk rather than the last one: a scalar
  # would describe only the final request, and the page a loop is most likely to wrap in a
  # transaction is the second one, where the writer has already run.
  it "holds no application transaction across any fetch, on any page" do
    observed = []
    transport = fixture_transport(scenario: "paginated")
    configuration = configuration_with("MAX_PAGES_PER_POLL" => "3", "GITHUB_MODE" => "fixture")
    watching = Class.new do
      define_method(:get) do |url, headers: {}|
        transaction = ActiveRecord::Base.lease_connection.current_transaction
        observed << (transaction.open? && transaction.joinable?)
        transport.get(url, headers: headers)
      end
    end.new

    ingest(fixture_runner(configuration: configuration,
                          executor: fixture_executor(transport: watching, ledger: ledger_for(configuration))))

    expect(observed.size).to eq(3)
    expect(observed).to all(be(false))
  end

  # §9's poll cadence. Nothing fires it on a schedule until PR 8 — this is the gate every
  # caller passes through, whoever calls it.
  describe "the poll cadence" do
    let(:transport) { fixture_transport }

    before { ingest(fixture_runner(transport: transport)) }

    it "defers a second poll inside the cadence window without asking GitHub" do
      result = ingest(fixture_runner(transport: transport, now: frozen_time + 60))

      expect(result).to be_deferred
      expect(result.deferral_reason).to eq("cadence_due_at")
      expect(result.next_poll_at).to eq(frozen_time + 300)
      expect(transport.requests.size).to eq(1)
      expect(current_budget.poll_used).to eq(1)
    end

    it "opens no run row for a poll it decided not to make" do
      expect { ingest(fixture_runner(transport: transport, now: frozen_time + 60)) }
        .not_to change(IngestionRun, :count).from(1)
    end

    it "polls again once the cadence has elapsed" do
      result = ingest(fixture_runner(transport: transport, now: frozen_time + 300))

      expect(result).to be_not_modified
      expect(current_budget.poll_used).to eq(2)
    end
  end

  # §9: "--force bypasses the application's configured cadence (cadence_due_at) and omits
  # the stored ETag — nothing else." Both halves, and then the four things it must not
  # touch. PollSchedule's spec proves the same rule as a unit; these prove the wiring.
  describe "--force" do
    let(:transport) { fixture_transport }

    before { ingest(fixture_runner(transport: transport)) }

    it "polls inside the cadence window" do
      result = ingest(fixture_runner(transport: transport, now: frozen_time + 60), force: true)

      expect(result).not_to be_deferred
      expect(transport.requests.size).to eq(2)
    end

    it "omits the stored ETag, so the poll is unconditional" do
      ingest(fixture_runner(transport: transport, now: frozen_time + 60), force: true)

      expect(transport.requests.map { |request| request[:headers]["if-none-match"] }).to all(be_nil)
    end

    it "does not bypass the poll allowance" do
      active_budget_window(now: frozen_time, poll_used: 12, poll_allowance: 12)

      result = ingest(fixture_runner(transport: transport, now: frozen_time + 60), force: true)

      expect(result).to be_deferred
      expect(result.deferral_reason).to eq("poll_class_blocked_until")
    end

    it "does not bypass a global block" do
      current_budget.update!(global_blocked_until: frozen_time + 1800)

      result = ingest(fixture_runner(transport: transport, now: frozen_time + 60), force: true)

      expect(result).to be_deferred
      expect(result.deferral_reason).to eq("global_blocked_until")
    end

    it "does not bypass GitHub's own poll floor" do
      # The corpus sends x-poll-interval: 60 on every response, so the first run already
      # wrote one.
      result = ingest(fixture_runner(transport: transport, now: frozen_time + 30), force: true)

      expect(result).to be_deferred
      expect(result.deferral_reason).to eq("poll_floor_until")
    end

    # SourceLock.acquire wraps the call before `force` is ever read, so this holds by
    # construction rather than by a check anyone could remove.
    it "does not bypass the source lock" do
      other_session_holding(Github::AdvisoryLock::SOURCE_LOCK_NAMESPACE,
                            Github::AdvisoryLock.key_for(event_source.id)) do
        expect { ingest(fixture_runner(transport: transport), force: true) }
          .to raise_error(Github::Errors::SourceBusy)
      end
    end
  end

  # §9's Link-driven walk, end to end and offline. The page-loop spec covers the stop
  # conditions; this proves the runner threads one tally, one run row, and one poll-state
  # write across all three pages.
  describe "a multi-page poll" do
    let(:configuration) { configuration_with("MAX_PAGES_PER_POLL" => "3", "GITHUB_MODE" => "fixture") }

    let!(:result) do
      ingest(fixture_runner(transport: fixture_transport(scenario: "paginated"),
                            configuration: configuration))
    end

    it "records every page in one run" do
      expect(result).to be_completed
      expect(result.tally.to_h).to include(pages_fetched: 3, events_received: 11, events_created: 6,
                                           duplicates_skipped: 1)
      expect(IngestionRun.sole).to have_attributes(pages_fetched: 3, events_created: 6)
    end

    it "debits one poll attempt per page" do
      expect(current_budget.poll_used).to eq(3)
    end
  end

  # §9's persisted poll state, per terminal outcome. PollState's own spec covers the write
  # matrix; these are the two ends of the wire.
  describe "persisted poll state" do
    it "records the schedule, the ETag, and the server floor after a healthy poll" do
      ingest

      expect(event_source.reload).to have_attributes(
        last_polled_at: frozen_time, last_success_at: frozen_time,
        cadence_due_at: frozen_time + 300, poll_floor_until: frozen_time + 60,
        etag: 'W/"3f2a1c9d0b7e4a58c1d2e3f4a5b6c7d8"', consecutive_failures: 0,
        retry_not_before_at: nil, next_poll_at: frozen_time + 300, status: "idle"
      )
    end

    it "blocks globally and defers the source when GitHub reports the limit exhausted" do
      ingest(fixture_runner(transport: fixture_transport(scenario: "rate_limited")))

      expect(current_budget.global_blocked_until).to eq(frozen_time + 3600)
      expect(event_source.reload).to have_attributes(consecutive_failures: 0,
                                                     cadence_due_at: frozen_time + 300)
    end

    it "blocks globally from Retry-After on a secondary limit, and defers this source too" do
      ingest(fixture_runner(transport: fixture_transport(scenario: "secondary_rate_limited")))

      expect(current_budget.global_blocked_until).to eq(frozen_time + 60)
      expect(event_source.reload).to have_attributes(retry_not_before_at: frozen_time + 60,
                                                     consecutive_failures: 0)
    end

    it "counts a failure and backs off after a server error outlives its retries" do
      ingest(fixture_runner(transport: fixture_transport(scenario: "transient_failure_exhausted")))

      expect(event_source.reload).to have_attributes(consecutive_failures: 1, last_success_at: nil)
      expect(event_source.retry_not_before_at).to be >= frozen_time + 60
    end
  end

  # §10: "/events returns permanent 4xx → source failed/disabled". The state is only
  # meaningful if something enforces it — otherwise it is a label that lies, and the source
  # keeps spending quota on a request that cannot succeed.
  describe "a source taken out of service" do
    let(:transport) { fixture_transport }

    before { event_source.update!(status: "failed", last_error: "GitHub returned 404 (not_found)") }

    it "is not polled at all" do
      result = ingest(fixture_runner(transport: transport))

      expect(result).to be_deferred
      expect(result.deferral_reason).to eq("source_failed")
      expect(transport.requests).to be_empty
      expect(current_budget.poll_used).to eq(0)
    end

    it "opens no run row, because nothing tried to reach GitHub" do
      expect { ingest(fixture_runner(transport: transport)) }.not_to change(IngestionRun, :count).from(0)
    end

    # §9 enumerates what --force bypasses, and this is not on the list. Recovery is an
    # operator's decision, not a flag's.
    it "is not polled under --force either" do
      result = ingest(fixture_runner(transport: transport), force: true)

      expect(result.deferral_reason).to eq("source_failed")
      expect(transport.requests).to be_empty
    end

    it "stays out of service until an operator clears it" do
      ingest(fixture_runner(transport: transport))
      expect(event_source.reload).to be_failed

      event_source.update!(status: "idle")

      expect(ingest(fixture_runner(transport: transport))).to be_completed
    end

    # The one path that could have quietly returned a source to service on its own.
    it "is never returned to service by a later success" do
      event_source.update!(status: "idle")
      ingest(fixture_runner(transport: transport))
      event_source.update!(status: "failed")

      ingest(fixture_runner(transport: fixture_transport, now: frozen_time + 301))

      expect(event_source.reload).to be_failed
    end
  end

  describe "an unexpected error" do
    it "finalizes the run as failed and re-raises, so no row is abandoned in running" do
      writer = instance_double(Github::Ingestion::PageWriter)
      allow(writer).to receive(:write).and_raise(RuntimeError, "boom")

      expect { ingest(fixture_runner(writer: writer)) }.to raise_error(RuntimeError, "boom")

      expect(IngestionRun.sole).to be_failed
      expect(IngestionRun.sole.last_error).to eq("RuntimeError: boom")
      expect(IngestionRun.sole.completed_at).to eq(frozen_time)
    end

    # The request was already spent when this crashed, so the poll has to count as an
    # attempt. Left unrecorded, the source is immediately due again and the next
    # invocation spends another request into the same crash, once per invocation, for as
    # long as the crash lasts.
    it "records an attempted poll when the crash happened after a page came back" do
      writer = instance_double(Github::Ingestion::PageWriter)
      allow(writer).to receive(:write).and_raise(RuntimeError, "boom")

      expect { ingest(fixture_runner(writer: writer)) }.to raise_error(RuntimeError, "boom")

      expect(event_source.reload).to have_attributes(
        last_polled_at: frozen_time, cadence_due_at: frozen_time + 300,
        consecutive_failures: 1, last_error: "RuntimeError: boom", last_success_at: nil
      )
      expect(event_source.retry_not_before_at).to be >= frozen_time + 60
    end

    it "leaves the schedule alone when nothing was ever fetched" do
      runner = fixture_runner
      allow(Github::EventSources::Base).to receive(:for).and_raise(RuntimeError, "boom")

      expect { ingest(runner) }.to raise_error(RuntimeError, "boom")

      expect(event_source.reload).to have_attributes(last_polled_at: nil, cadence_due_at: nil,
                                                     consecutive_failures: 0)
    end

    # Errors::FixtureMiss is re-raised by the executor because §6 requires a corpus gap to
    # be an authoring error, never laundered into a retryable failure. The run row still
    # has to be closed.
    it "closes the run before letting a corpus gap escape" do
      empty_corpus = Github::FixtureCorpus.load(root: Rails.root.join("fixtures", "github"),
                                                scenario: "default")
      allow(empty_corpus).to receive(:responses_for).and_return(nil)
      transport = Github::Transports::Fixture.new(corpus: empty_corpus, clock: -> { frozen_time })

      expect { ingest(fixture_runner(transport: transport)) }
        .to raise_error(Github::Errors::FixtureMiss)

      expect(IngestionRun.sole).to be_failed
      expect(IngestionRun.sole.last_error).to include("FixtureMiss")
    end
  end

  describe "the run summary log lines" do
    it "reports §11's counts at INFO, including the one with no column" do
      allow(Rails.logger).to receive(:info)

      ingest

      expect(Rails.logger).to have_received(:info).with(
        hash_including(event: "ingestion.run_completed", run_status: "completed",
                       events_created: 4, duplicates_skipped: 0, events_quarantined: 3,
                       events_ignored: 1)
      )
    end

    it "opens the run with the correlation fields and the force flag" do
      allow(Rails.logger).to receive(:info)

      ingest(fixture_runner, force: true)

      expect(Rails.logger).to have_received(:info).with(
        hash_including(event: "ingestion.run_started", event_source_id: event_source.id,
                       source_type: "github_fixture_events",
                       github_mode: Github.configuration.mode, forced: true)
      )
    end

    # §11's correlation identifier reaches the per-request DEBUG line too, which is the line
    # a reviewer turns on to trace one run.
    it "carries run_id onto the request line" do
      allow(Rails.logger).to receive(:debug)

      result = ingest

      expect(Rails.logger).to have_received(:debug)
        .with(hash_including(event: "github.request", run_id: result.run_id)).at_least(:once)
    end
  end

  def empty_page_transport
    scripted_transport(status: 200, body: "[]")
  end

  def object_body_transport
    scripted_transport(status: 200, body: '{"message":"Not Found"}')
  end

  def scripted_transport(status:, body:)
    response = Github::Transports::Response.new(
      status: status, headers: Github::Transports::Response.normalize({}), body: body,
      url: nil, duration_ms: 0.0
    )

    Class.new do
      define_method(:get) { |_url, headers: {}| response }
    end.new
  end
end
