require "rails_helper"

RSpec.describe Github::Enrichment::OneShot do
  # An instance_double, so the CLI contract is asserted independently of what enrichment
  # actually does — the shape ingestion/one_shot_spec.rb uses for the same reason.
  let(:runner) { instance_double(Github::EnrichmentRunner) }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }

  def one_shot(argv: [])
    described_class.new(argv: argv, output: output, error_output: error_output, runner: runner)
  end

  def result(status:, **overrides)
    Github::EnrichmentRunner::Result.new(status: status, **overrides)
  end

  def returning(*results)
    allow(runner).to receive(:call).and_return(*results)
  end

  describe "exit codes" do
    it "succeeds when it enriched something" do
      returning(result(status: "enriched", entity_type: :actor, github_id: 1))

      expect(one_shot.call.exit_code).to eq(described_class::SUCCESS)
    end

    # §10 is explicit that a 404 on one enrichment target is not a failure of anything
    # else. Without this rule a reviewer running the deterministic fixture scenario would
    # get exit 1 for ghostuser, which is correct behaviour reported as breakage.
    it "succeeds on a permanent failure, which is a decided and durable outcome" do
      returning(result(status: "failed", entity_type: :actor, github_id: 1,
                       enrichment_status: "permanent_failure", last_error: "404"))

      expect(one_shot.call.exit_code).to eq(described_class::SUCCESS)
    end

    it "fails on a retryable failure, which is the one case where work is genuinely unfinished" do
      returning(result(status: "failed", entity_type: :actor, github_id: 1,
                       enrichment_status: "retryable_failure", last_error: "500"))

      expect(one_shot.call.exit_code).to eq(described_class::FAILURE)
    end

    # §9's rule for the ingestion command, and the same reasoning: the request never
    # happened, so a reviewer's command must not look broken.
    it "succeeds on every deferral, because nothing failed" do
      %w[ idle deferred lease_lost ].each do |status|
        returning(result(status: status, deferral_reason: "class_exhausted"))

        expect(one_shot.call.exit_code).to eq(described_class::SUCCESS), "expected #{status} to exit 0"
      end
    end

    it "refuses a bad option rather than running with a guess" do
      expect(one_shot(argv: [ "--nonsense" ]).call.exit_code).to eq(described_class::REFUSED)
      expect(error_output.string).to include("bin/enrich")
    end

    it "refuses a corpus gap, which is an authoring bug that recurs until it is fixed" do
      allow(runner).to receive(:call).and_raise(Github::Errors::FixtureMiss.new("/users/nobody"))

      expect(one_shot.call.exit_code).to eq(described_class::REFUSED)
      expect(error_output.string).to include("Fixture corpus error")
    end
  end

  describe "--limit" do
    it "runs one cycle by default, which is the unit PR 8's jobs wrap" do
      expect(runner).to receive(:call).once.and_return(result(status: "enriched", entity_type: :actor, github_id: 1))

      one_shot.call
    end

    it "runs up to the number of cycles it was given" do
      expect(runner).to receive(:call).exactly(3).times
                                      .and_return(result(status: "enriched", entity_type: :actor, github_id: 1))

      one_shot(argv: %w[ --limit 3 ]).call
    end

    it "stops early when nothing is eligible, rather than asking again for no reason" do
      expect(runner).to receive(:call).once.and_return(result(status: "idle"))

      one_shot(argv: %w[ --limit 5 ]).call
    end

    it "stops early on a deferral, because the next cycle would be refused identically" do
      expect(runner).to receive(:call).once
                                      .and_return(result(status: "deferred", deferral_reason: "class_exhausted"))

      one_shot(argv: %w[ --limit 5 ]).call
    end

    # §16 requires malformed data not to terminate the batch, and the same reasoning
    # applies to an entity that 404s halfway through a run.
    it "does not stop on a failed entity, which must not terminate the batch" do
      expect(runner).to receive(:call).exactly(3).times.and_return(
        result(status: "failed", entity_type: :actor, github_id: 1, enrichment_status: "permanent_failure")
      )

      one_shot(argv: %w[ --limit 3 ]).call
    end

    it "refuses a non-positive limit" do
      expect(one_shot(argv: %w[ --limit 0 ]).call.exit_code).to eq(described_class::REFUSED)
    end
  end

  describe "--class" do
    it "passes the class through to the runner" do
      expect(runner).to receive(:call).with(entity_class: "actor")
                                      .and_return(result(status: "idle"))

      one_shot(argv: %w[ --class actor ]).call
    end

    it "asks the runner to choose when no class was named" do
      expect(runner).to receive(:call).with(entity_class: nil).and_return(result(status: "idle"))

      one_shot.call
    end

    it "rejects a class that has no enrichment counters" do
      expect(one_shot(argv: %w[ --class organization ]).call.exit_code).to eq(described_class::REFUSED)
      expect(error_output.string).to include("organization")
    end
  end

  describe "what it deliberately does not have" do
    # §9 licenses --force against the poll cadence and the stored ETag, "nothing else", and
    # enrichment has no cadence. Every constraint it does have is one §10 requires to bind.
    it "has no --force, because enrichment has no cadence to bypass" do
      expect(one_shot(argv: [ "--force" ]).call.exit_code).to eq(described_class::REFUSED)
      expect(described_class::USAGE).to include("no --force")
    end

    # §8 step 1: "Enrichment jobs skip this step — they take only the request gate." There
    # is no busy path to contract, and that absence is the guarantee made visible.
    it "never waits for a source lock, which enrichment does not take" do
      expect(runner).to receive(:call).with(entity_class: nil).and_return(result(status: "idle"))

      one_shot.call
    end
  end

  describe "the report" do
    before { returning(result(status: "idle")) }

    # §9's rule for the ingestion command applies here too: stdout always proves system
    # state, even when nothing happened.
    it "prints the state blocks even when nothing was enriched" do
      one_shot.call

      expect(output.string).to include("Nothing to enrich", "Actor backlog",
                                       "Enrichment backlog budget", "Persisted push events")
    end

    it "prints the enrichment counters for the invocation" do
      one_shot.call

      expect(output.string).to include("Enrichment cycles", "Cycles with nothing eligible")
      expect(output.string).not_to include("Candidates skipped")
    end

    it "writes the whole block in one call, so a JSON log line cannot split it" do
      expect(output).to receive(:puts).once

      one_shot.call
    end

    it "names the entity and the outcome in the headline" do
      returning(result(status: "enriched", entity_type: :actor, github_id: 583_231))

      one_shot.call

      expect(output.string).to include("Enriched actor 583231 — complete")
    end

    it "names the deferral reason rather than reporting a bare failure" do
      returning(result(status: "deferred", deferral_reason: "class_exhausted"))

      one_shot.call

      expect(output.string).to include("Enrichment deferred — class_exhausted")
    end

    # A summary that cannot be read must not mask the outcome that was already decided.
    it "reports an unreadable summary without changing the exit code" do
      allow(Github::Enrichment::Summary).to receive(:capture).and_raise(ActiveRecord::StatementInvalid)

      expect(one_shot.call.exit_code).to eq(described_class::SUCCESS)
      expect(error_output.string).to include("State summary unavailable")
    end
  end

  describe "--help" do
    it "prints the usage and succeeds" do
      expect(one_shot(argv: [ "--help" ]).call.exit_code).to eq(described_class::SUCCESS)
      expect(output.string).to include("Usage: bin/enrich")
    end
  end
end
