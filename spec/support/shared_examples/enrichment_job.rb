# EnrichActorJob and EnrichRepositoryJob are the same job over §7's identical state machine,
# so their contract is written once — the precedent spec/support/shared_examples/
# enrichable_entity.rb set for the models themselves.
#
# What is actually being asserted is the job's *boundary*: which class it asks for, that one
# call is one entity, that it never reaches for a source lock, and that an outcome nobody has
# to act on is not an error.
RSpec.shared_examples "an enrichment job" do |entity_class:, entity_type:, log_key:|
  let(:runner) { instance_double(Github::EnrichmentRunner) }
  let(:enriched) do
    Github::EnrichmentRunner::Result.new(status: "enriched", entity_type: entity_type, github_id: 4_242)
  end

  before { allow(Github::EnrichmentRunner).to receive(:new).and_return(runner) }

  it "runs exactly one cycle, narrowed to its own class" do
    expect(runner).to receive(:call).with(entity_class: entity_class).once.and_return(enriched)

    described_class.new.perform_now
  end

  it "joins the cycle to the job on one line" do
    allow(runner).to receive(:call).and_return(enriched)
    allow(Rails.logger).to receive(:info)

    job = described_class.new
    job.perform_now

    expect(Rails.logger).to have_received(:info).with(
      hash_including(event: "job.completed", job_id: job.job_id, job_class: described_class.name,
                     log_key => 4_242, enrichment_outcome: "enriched")
    )
  end

  # §8 step 1: "Enrichment jobs skip this step — they take only the request gate." Asserted at
  # the job boundary as well as inside the runner, because this is where a future "just lock
  # the source while we enrich it" would be written.
  it "never takes a source lock" do
    allow(runner).to receive(:call).and_return(enriched)
    expect(Github::SourceLock).not_to receive(:acquire)

    described_class.new.perform_now

    expect(Github::LockOrder.held_keys).to be_empty
  end

  # Nothing eligible, or a ledger that refused: ordinary outcomes of a system whose budget is
  # 40 requests an hour. Failing the job would fill solid_queue_failed_executions with the
  # steady state.
  %w[idle deferred].each do |status|
    it "treats a #{status} cycle as a completed job" do
      allow(runner).to receive(:call)
        .and_return(Github::EnrichmentRunner::Result.new(status: status, deferral_reason: "no_candidate"))

      expect { described_class.new.perform_now }.not_to raise_error
    end
  end

  # §6 requires a corpus gap to be raised rather than laundered into a failed fetch, and the
  # runner has already put the lease back by the time it arrives here.
  it "lets a fixture corpus gap fail the job" do
    allow(runner).to receive(:call).and_raise(Github::Errors::FixtureMiss, "no such body")

    expect { described_class.new.perform_now }.to raise_error(Github::Errors::FixtureMiss)
  end
end
