require "rails_helper"

RSpec.describe Github::Ingestion::OneShot do
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:runner) { instance_double(Github::IngestionRunner) }

  def one_shot(argv: [])
    described_class.new(argv: argv, output: output, error_output: error_output, runner: runner)
  end

  def runner_returns(status:, tally: Github::Ingestion::Tally.empty, **overrides)
    result = Github::IngestionRunner::Result.new(
      **{ run_id: "2f5b9c3e", status: status, tally: tally, classification: :ok,
          last_error: nil, deferral_reason: nil }.merge(overrides)
    )

    allow(runner).to receive(:call).and_return(result)
    result
  end

  def printed = output.string

  describe "a completed run" do
    let(:tally) do
      Github::Ingestion::Tally.empty
        .record_page(events_received: 8)
        .record(result: :created, push_type: true)
        .record(result: :quarantined, push_type: true)
    end

    before { runner_returns(status: "completed", tally: tally) }

    it "succeeds" do
      expect(one_shot.call).to have_attributes(outcome: :completed, exit_code: 0)
    end

    # §9: "On a live run it prints the end-of-run summary: pages fetched, events seen, push
    # events created, duplicates skipped, events quarantined, budget remaining."
    it "prints the run headline, the counters, and then the state summary" do
      one_shot.call

      expect(printed).to include("Ingestion run 2f5b9c3e completed")
      expect(printed).to include("Pages fetched:", "Events seen:", "Push events created:",
                                 "Duplicates skipped:", "Events quarantined:")
      expect(printed).to include("Persisted push events:", "Budget remaining (core):")
    end

    it "polls the source it provisions, waiting the configured lock time" do
      expect(runner).to receive(:call)
        .with(event_source: instance_of(EventSource),
              wait_seconds: Github.configuration.source_lock_wait_seconds, force: false)
        .and_return(Github::IngestionRunner::Result.new(
                      run_id: "2f5b9c3e", status: "completed", tally: tally,
                      classification: :ok, last_error: nil, deferral_reason: nil
                    ))

      one_shot.call
    end

    it "provisions the event source a clean checkout does not have" do
      expect { one_shot.call }.to change(EventSource, :count).by(1)
    end
  end

  describe "a 304" do
    it "succeeds and says the feed had nothing new" do
      runner_returns(status: "not_modified", classification: :not_modified)

      expect(one_shot.call).to have_attributes(outcome: :not_modified, exit_code: 0)
      expect(printed).to include("GitHub reported no changes (304)")
    end
  end

  # §9's contention contract, and the one exit code the plan pins explicitly.
  describe "a source the poller already owns" do
    before { allow(runner).to receive(:call).and_raise(Github::Errors::SourceBusy) }

    it "exits 0 with §9's wording" do
      expect(one_shot.call).to have_attributes(outcome: :busy, exit_code: 0)
      expect(printed).to include("source busy — poller cycle in progress")
    end

    # §9: "Its stdout always proves system state, even when deferred or busy."
    it "still prints the state summary" do
      one_shot.call

      expect(printed).to include("Latest successful run:", "Persisted push events:")
    end

    it "prints no run counters, because no run happened" do
      one_shot.call

      expect(printed).not_to include("Pages fetched:")
    end
  end

  # §10: a budget denial, a held gate and a rate-limit response mean the request never
  # happened. A reviewer's command must not look broken because the system was busy.
  describe "a deferred run" do
    it "exits 0 and names the reason" do
      runner_returns(status: "deferred", classification: :budget_denied,
                     deferral_reason: "class_allowance_exhausted")

      expect(one_shot.call).to have_attributes(outcome: :deferred, exit_code: 0)
      expect(printed).to include("Ingestion deferred — class_allowance_exhausted")
    end

    # §9's line is "Ingestion deferred until T", where T is effective_poll_time — computed
    # by the runner against the same `force` the run used, and handed over on the Result.
    # That is what lets every scheduling deferral name an honest instant instead of
    # borrowing the ledger's window reset and hoping it fits.
    it "names the instant the runner computed" do
      runner_returns(status: "deferred", classification: nil, deferral_reason: "cadence_due_at",
                     next_poll_at: frozen_time + 300)

      one_shot.call

      expect(printed).to include("Ingestion deferred until #{(frozen_time + 300).iso8601} — cadence_due_at")
    end

    it "names it for the response-driven deferrals PR 6 gave an instant to" do
      %w[rate_limited secondary_limited globally_blocked poll_class_blocked_until].each do |reason|
        output.truncate(output.rewind)
        runner_returns(status: "deferred", deferral_reason: reason, next_poll_at: frozen_time + 900)

        one_shot.call

        expect(printed).to include("Ingestion deferred until #{(frozen_time + 900).iso8601} — #{reason}")
      end
    end

    # A ledger denial reflecting GitHub's own `remaining` rather than this application's
    # plan: it is not a term of §9's formula, so effective_poll_time can sit in the past
    # while the ledger still refuses, and the window reset is the honest instant. Making
    # the reserve a scheduling component was the tempting simplification and is wrong — a
    # co-tenant's window rolling can clear it at any moment.
    it "falls back to the window reset for a reserve breach, which the formula does not model" do
      active_budget_window(now: frozen_time)
      runner_returns(status: "deferred", classification: :budget_denied,
                     deferral_reason: "reserve_reached", next_poll_at: nil)

      one_shot.call

      expect(printed).to include("Ingestion deferred until #{(frozen_time + 3600).iso8601}")
    end

    # A held gate clears when whoever holds it lets go. Naming a time would be a confident
    # wrong answer, which is worse than no answer.
    it "states the reason alone for a held gate, which has no instant at all" do
      active_budget_window(now: frozen_time)
      runner_returns(status: "deferred", classification: :gate_unavailable,
                     deferral_reason: "gate_unavailable", next_poll_at: frozen_time + 900)

      one_shot.call

      expect(printed).to include("Ingestion deferred — gate_unavailable")
      expect(printed).not_to include("deferred until")
    end

    # A pre-flight deferral never opened a run row, so there is no run_id to interpolate —
    # the deferral line is the one outcome line that does not name one.
    it "prints a deferral that never opened a run" do
      runner_returns(status: "deferred", run_id: nil, classification: nil,
                     deferral_reason: "poll_floor_until", next_poll_at: frozen_time + 60)

      expect(one_shot.call).to have_attributes(outcome: :deferred, exit_code: 0)
      expect(printed).to include("Ingestion deferred until #{(frozen_time + 60).iso8601} — poll_floor_until")
    end

    # Seven zeroes would suggest a run that produced nothing rather than one that never
    # happened, and under a five-minute cadence a deferral is the common outcome of this
    # command rather than an unusual one.
    it "prints no counters, because nothing was fetched" do
      runner_returns(status: "deferred", deferral_reason: "cadence_due_at",
                     next_poll_at: frozen_time + 300)

      one_shot.call

      expect(printed).not_to include("Pages fetched:")
      expect(printed).to include("Persisted push events:")
    end

    it "prints the state summary too" do
      runner_returns(status: "deferred", deferral_reason: "gate_unavailable")

      one_shot.call

      expect(printed).to include("Budget remaining")
    end
  end

  describe "a failed run" do
    before do
      runner_returns(status: "failed", classification: :server_error,
                     last_error: "GitHub returned 500 (server_error)")
    end

    it "exits 1 and says what happened" do
      expect(one_shot.call).to have_attributes(outcome: :failed, exit_code: 1)
      expect(printed).to include("failed: GitHub returned 500 (server_error)")
    end

    it "still proves system state" do
      one_shot.call

      expect(printed).to include("Persisted push events:")
    end
  end

  # §6 requires fixture mode to fail closed, and the executor deliberately re-raises a corpus
  # gap. "Fix the corpus" is not the same outcome as "GitHub failed", so it is not exit 1.
  describe "an invocation or an environment that refuses to run" do
    it "exits 2 on a corpus gap, on stderr, and still prints state" do
      allow(runner).to receive(:call).and_raise(Github::Errors::FixtureMiss, "no response for \"/events\"")

      expect(one_shot.call).to have_attributes(outcome: :refused, exit_code: 2)
      expect(error_output.string).to include("Fixture corpus error: no response for")
      expect(printed).to include("Persisted push events:")
    end

    it "exits 2 on a configuration the process must not run with" do
      allow(runner).to receive(:call).and_raise(Github::Errors::ConfigurationError, "POLL_INTERVAL_SECONDS")

      expect(one_shot.call.exit_code).to eq(2)
      expect(error_output.string).to include("Configuration error: POLL_INTERVAL_SECONDS")
    end

    it "exits 2 on an unknown option, without touching the database" do
      expect(runner).not_to receive(:call)

      expect { expect(one_shot(argv: %w[--turbo]).call.exit_code).to eq(2) }
        .not_to change(EventSource, :count)
      expect(error_output.string).to include("invalid option: --turbo", "Usage: bin/ingest")
    end

    it "exits 2 on a stray positional argument" do
      expect(one_shot(argv: %w[now]).call.exit_code).to eq(2)
      expect(error_output.string).to include('unexpected argument "now"')
    end
  end

  describe "--force" do
    it "reaches the runner" do
      expect(runner).to receive(:call).with(hash_including(force: true))
                                      .and_return(Github::IngestionRunner::Result.new(
                                                    run_id: "2f5b9c3e", status: "completed",
                                                    tally: Github::Ingestion::Tally.empty,
                                                    classification: :ok, last_error: nil,
                                                    deferral_reason: nil
                                                  ))

      expect(one_shot(argv: %w[--force]).call.exit_code).to eq(0)
    end

    # §9 is precise about the blast radius, and so is the help text: a reviewer reaching
    # for --force to make a demo work has to be able to see it cannot blow the budget or
    # poll faster than GitHub asks.
    it "documents both what it bypasses and what it does not" do
      one_shot(argv: %w[--help]).call

      expect(printed).to include("Ignore the configured poll cadence and omit the stored ETag")
      expect(printed).to include("does not bypass the source lock")
      expect(printed).not_to include("No effect yet")
    end
  end

  describe "--help" do
    it "prints usage, succeeds, and runs nothing" do
      expect(runner).not_to receive(:call)

      expect(one_shot(argv: %w[--help]).call).to have_attributes(outcome: :help, exit_code: 0)
      expect(printed).to include("Usage: bin/ingest", "--force", "Exit codes:")
    end
  end

  # The only exit in the application is bin/ingest's. Returning the code is what makes every
  # example above a unit test rather than a shelled-out one.
  it "never ends the process itself" do
    runner_returns(status: "completed")

    expect(one_shot.call.exit_code).to be_an(Integer)
  end

  describe "bin/ingest" do
    let(:script) { Rails.root.join("bin", "ingest") }

    # A lost executable bit breaks `docker compose run --rm ingest` and nothing else in the
    # suite would catch it.
    it "is executable" do
      expect(script.stat.mode & 0o111).not_to eq(0)
    end

    it "delegates rather than reimplementing the contract" do
      body = script.read

      expect(body).to include("Github::Ingestion::OneShot")
      expect(body.scan(/^\s*(if|unless|case)\b/)).to be_empty
    end
  end
end
