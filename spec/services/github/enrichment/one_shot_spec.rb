require "rails_helper"

RSpec.describe Github::Enrichment::OneShot do
  # instance_doubles, so the CLI contract — lanes, the request limit, exit codes, the
  # report — is asserted independently of what the runners actually do, the shape
  # ingestion/one_shot_spec.rb uses for the same reason.
  let(:batch_runner) { instance_double(Github::Enrichment::BatchRunner) }
  let(:detail_runner) { instance_double(Github::Enrichment::DetailRunner) }
  let(:admission) { instance_double(Github::Enrichment::Admission) }
  let(:batch_claim) { instance_double(Github::Enrichment::BatchClaim) }
  let(:detail_claim) { instance_double(Github::Enrichment::DetailClaim) }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }

  let(:granted) { Github::Enrichment::Admission::GRANTED }

  def denial(reason)
    Github::Enrichment::Admission::Verdict.new(reason: reason, retry_in_seconds: nil)
  end

  def one_shot(argv: [])
    described_class.new(argv: argv, output: output, error_output: error_output,
                        batch_runner: batch_runner, detail_runner: detail_runner,
                        admission: admission, batch_claim: batch_claim,
                        detail_claim: detail_claim)
  end

  def batch_result(status:, **overrides)
    defaults = { status: status, entity_type: :actor, batch_id: 41, requested_count: 3,
                 returned_count: 3, valid_count: 2, fallback_count: 1, deferral_reason: nil }

    Github::Enrichment::BatchRunner::Result.new(**defaults.merge(overrides))
  end

  def detail_result(status:, **overrides)
    defaults = { status: status, entity_type: :actor, github_id: 583_231, batch_id: 42,
                 reason: nil }

    Github::Enrichment::DetailRunner::Result.new(**defaults.merge(overrides))
  end

  # Both lanes admissible and empty by default; each example states only its deviation.
  before do
    allow(admission).to receive(:search).and_return(granted)
    allow(admission).to receive(:detail).and_return(granted)
    allow(batch_claim).to receive(:claimable?).and_return(false)
    allow(detail_claim).to receive(:claimable?).and_return(false)
  end

  def batch_work!
    allow(batch_claim).to receive(:claimable?).and_return(true)
  end

  def detail_work!
    allow(detail_claim).to receive(:claimable?).and_return(true)
  end

  describe "exit codes" do
    it "succeeds when a batch applied its items" do
      batch_work!
      allow(batch_runner).to receive(:call).and_return(batch_result(status: "completed"))

      expect(one_shot.call.exit_code).to eq(described_class::SUCCESS)
    end

    # §10 is explicit that a confirmed-gone entity is a decided, durable outcome. Without
    # this rule a reviewer running the deterministic fixture scenario would get exit 1 for
    # ghostuser — correct behaviour reported as breakage.
    it "succeeds on a terminal detail outcome, which is decided and durable" do
      detail_work!
      allow(detail_runner).to receive(:call)
        .and_return(detail_result(status: "terminal", reason: "entity_gone_404"))

      expect(one_shot(argv: %w[ --stage detail ]).call.exit_code).to eq(described_class::SUCCESS)
    end

    it "fails when a batch failed, which schedules retries for every claimed item" do
      batch_work!
      allow(batch_runner).to receive(:call)
        .and_return(batch_result(status: "failed", deferral_reason: "search_http_500"))

      expect(one_shot.call.exit_code).to eq(described_class::FAILURE)
    end

    it "fails when a detail attempt is scheduled to be retried" do
      detail_work!
      allow(detail_runner).to receive(:call)
        .and_return(detail_result(status: "retry_scheduled", reason: "502"))

      expect(one_shot(argv: %w[ --stage detail ]).call.exit_code).to eq(described_class::FAILURE)
    end

    # §9's rule for the ingestion command, and the same reasoning: the request never
    # happened, so a reviewer's command must not look broken.
    it "succeeds on a ledger deferral, because nothing failed" do
      batch_work!
      allow(batch_runner).to receive(:call)
        .and_return(batch_result(status: "deferred", deferral_reason: "search_reserve_reached"))

      expect(one_shot.call.exit_code).to eq(described_class::SUCCESS)
    end

    # A lease lost to a concurrent worker means the entity was decided elsewhere — work
    # happened, just not here.
    it "succeeds on a lost lease and an empty backlog alike" do
      expect(one_shot.call.exit_code).to eq(described_class::SUCCESS)

      detail_work!
      allow(detail_runner).to receive(:call).and_return(detail_result(status: "lease_lost"))

      expect(one_shot(argv: %w[ --stage detail ]).call.exit_code).to eq(described_class::SUCCESS)
    end

    # There is no pacing sleep here: the always-on cycle waits pacing out, a one-shot
    # reports the truth and exits 0. The unstubbed batch_runner double is itself the
    # proof that no request was attempted — a call would raise.
    it "reports a pacing denial and stops without a request" do
      batch_work!
      allow(admission).to receive(:search).and_return(denial(:search_pacing))

      result = one_shot(argv: %w[ --stage batch ]).call

      expect(result.exit_code).to eq(described_class::SUCCESS)
      expect(output.string).to include("Search deferred — search_pacing")
    end

    it "refuses a bad option rather than running with a guess" do
      expect(one_shot(argv: [ "--nonsense" ]).call.exit_code).to eq(described_class::REFUSED)
      expect(error_output.string).to include("bin/enrich")
    end

    it "refuses a configuration the initializer would have refused" do
      batch_work!
      allow(batch_runner).to receive(:call)
        .and_raise(Github::Errors::ConfigurationError, "SEARCH_BATCH_SIZE must be positive")

      expect(one_shot.call.exit_code).to eq(described_class::REFUSED)
      expect(error_output.string).to include("Configuration error")
    end

    it "refuses a corpus gap, which is an authoring bug that recurs until it is fixed" do
      batch_work!
      allow(batch_runner).to receive(:call)
        .and_raise(Github::Errors::FixtureMiss.new("/search/users?q=user%3Anobody"))

      expect(one_shot.call.exit_code).to eq(described_class::REFUSED)
      expect(error_output.string).to include("Fixture corpus error")
    end
  end

  describe "--limit" do
    it "attempts one request by default" do
      batch_work!
      detail_work!
      expect(batch_runner).to receive(:call).once.and_return(batch_result(status: "completed"))

      one_shot.call
    end

    # The limit counts REQUESTS across both lanes, not entities and not lanes — a batch of
    # ten entities is one request against it.
    it "spends the request budget across both lanes in order" do
      allow(batch_claim).to receive(:claimable?).and_return(true, false, false)
      detail_work!
      expect(batch_runner).to receive(:call).once.with(entity_class: :actor)
                                            .and_return(batch_result(status: "completed"))
      expect(detail_runner).to receive(:call).once.with(entity_class: :actor, borrow: false)
                                             .and_return(detail_result(status: "completed"))

      expect(one_shot(argv: %w[ --limit 2 ]).call.exit_code).to eq(described_class::SUCCESS)
    end

    it "attempts up to the number of requests it was given" do
      batch_work!
      expect(batch_runner).to receive(:call).exactly(3).times
                                            .and_return(batch_result(status: "completed"))

      one_shot(argv: %w[ --limit 3 ]).call
    end

    # Two consecutive idle claims end a lane — the same race guard the cycle uses — so an
    # emptied backlog cannot spin the remaining limit away on claims.
    it "stops a lane after two consecutive idle claims" do
      batch_work!
      expect(batch_runner).to receive(:call).twice.and_return(batch_result(status: "idle"))

      one_shot(argv: %w[ --limit 5 --stage batch ]).call
    end

    it "stops on a deferral, because the next request would be refused identically" do
      batch_work!
      expect(batch_runner).to receive(:call).once
        .and_return(batch_result(status: "deferred", deferral_reason: "search_reserve_reached"))

      one_shot(argv: %w[ --limit 5 --stage batch ]).call

      expect(output.string).to include("Search batch deferred — search_reserve_reached")
    end

    # §16 requires malformed data not to terminate the batch, and the same reasoning
    # applies to a failed request halfway through a run.
    it "does not stop on a failed batch, which must not terminate the run" do
      batch_work!
      expect(batch_runner).to receive(:call).twice
        .and_return(batch_result(status: "failed", deferral_reason: "search_http_500"))

      expect(one_shot(argv: %w[ --limit 2 --stage batch ]).call.exit_code)
        .to eq(described_class::FAILURE)
    end

    it "refuses a non-positive limit" do
      expect(one_shot(argv: %w[ --limit 0 ]).call.exit_code).to eq(described_class::REFUSED)
    end
  end

  describe "--stage" do
    it "runs only the batch lane when asked, never consulting the detail side" do
      batch_work!
      detail_work!
      allow(batch_runner).to receive(:call).and_return(batch_result(status: "completed"))

      one_shot(argv: %w[ --stage batch ]).call

      expect(admission).not_to have_received(:detail)
    end

    it "runs only the detail lane when asked, never consulting the search side" do
      batch_work!
      detail_work!
      allow(detail_runner).to receive(:call).and_return(detail_result(status: "completed"))

      one_shot(argv: %w[ --stage detail ]).call

      expect(admission).not_to have_received(:search)
    end

    it "refuses a stage it does not have" do
      expect(one_shot(argv: %w[ --stage hourly ]).call.exit_code).to eq(described_class::REFUSED)
      expect(error_output.string).to include("hourly")
    end
  end

  describe "--class" do
    it "narrows selection to the named class without asking about the other" do
      batch_work!
      allow(batch_runner).to receive(:call).and_return(batch_result(status: "completed"))

      one_shot(argv: %w[ --class actor --stage batch ]).call

      expect(batch_runner).to have_received(:call).with(entity_class: :actor)
      expect(batch_claim).not_to have_received(:claimable?)
        .with(Github::Enrichment::EntityType.fetch(:repository))
    end

    it "rejects a class that has no enrichment lanes" do
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
      batch_work!
      allow(batch_runner).to receive(:call).and_return(batch_result(status: "completed"))
      expect(Github::SourceLock).not_to receive(:acquire)

      one_shot.call

      expect(Github::LockOrder.held_keys).to be_empty
    end
  end

  describe "the report" do
    # §9's rule for the ingestion command applies here too: stdout always proves system
    # state, even when nothing happened.
    it "prints the tally and both persisted-state blocks even when nothing was attempted" do
      one_shot.call

      expect(output.string).to include(
        "Nothing to enrich", "Requests attempted", "Actor contract backlog",
        "Search budget", "Detail fallback budget", "Persisted push events"
      )
    end

    it "writes the whole block in one call, so a JSON log line cannot split it" do
      expect(output).to receive(:puts).once

      one_shot.call
    end

    it "names the batch outcome in the headline" do
      batch_work!
      allow(batch_runner).to receive(:call).and_return(batch_result(status: "completed"))

      one_shot.call

      expect(output.string).to include("Search batch actor #41 — requested 3, valid 2, fallback 1")
    end

    it "names the detail outcome in the headline" do
      detail_work!
      allow(detail_runner).to receive(:call).and_return(detail_result(status: "completed"))

      one_shot(argv: %w[ --stage detail ]).call

      expect(output.string).to include("Detail actor 583231 — complete")
    end

    it "names the retry reason rather than reporting a bare failure" do
      detail_work!
      allow(detail_runner).to receive(:call)
        .and_return(detail_result(status: "retry_scheduled", reason: "502"))

      one_shot(argv: %w[ --stage detail ]).call

      expect(output.string).to include("Detail actor 583231 — retry scheduled: 502")
    end

    it "still prints the persisted state when it refused to run" do
      batch_work!
      allow(batch_runner).to receive(:call)
        .and_raise(Github::Errors::ConfigurationError, "SEARCH_BATCH_SIZE must be positive")

      one_shot.call

      expect(output.string).to include("Actor contract backlog", "Persisted push events")
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
