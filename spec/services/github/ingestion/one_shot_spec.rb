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

    # §9's line is "Ingestion deferred until T". PR 5 has no cadence to defer against, so the
    # instant it can honestly name is the window reset the ledger already knows.
    it "names the window reset when the ledger knows one" do
      active_budget_window(now: frozen_time)
      runner_returns(status: "deferred", classification: :budget_denied,
                     deferral_reason: "class_allowance_exhausted")

      one_shot.call

      expect(printed).to include("Ingestion deferred until #{(frozen_time + 3600).iso8601}")
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

  # Accepted now, inert now. What §9 says it bypasses — the configured cadence and the stored
  # ETag — is PR 6's, and neither exists yet; shipping the flag means the documented command
  # works today and the CLI surface does not change when PR 6 gives it teeth.
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

    it "is documented as inert until the poller lands" do
      one_shot(argv: %w[--help]).call

      expect(printed).to include("No effect yet")
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
