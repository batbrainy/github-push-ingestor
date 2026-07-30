require "rails_helper"

# The queue counterpart of spec/network_boundary_spec.rb. That file proves no spec can reach
# live GitHub; this one proves no ordinary spec can reach the queue database — §2A's other
# containment rule, and the one that silently stops holding if config/environments/test.rb's
# adapter override is ever dropped.
RSpec.describe "the job boundary" do
  it "runs the suite on Active Job's test adapter" do
    expect(ActiveJob::Base.queue_adapter).to be_a(ActiveJob::QueueAdapters::TestAdapter)
  end

  it "keeps that adapter in the test environment's own configuration" do
    expect(Rails.application.config.active_job.queue_adapter).to eq(:test)
  end

  # §2A's enqueue semantics. A default that flipped would move every enqueue in this
  # application inside the caller's transaction — the one boundary the outbox-style recovery
  # argument depends on.
  it "defers enqueues until after the enclosing transaction commits" do
    expect(ApplicationJob.enqueue_after_transaction_commit).to be(true)
  end

  # Solid Queue is what the worker container runs, so the routing has to be configured for
  # every environment rather than only for production, where nothing in this project runs.
  it "routes Solid Queue at the queue database in every environment" do
    expect(Rails.application.config.solid_queue.connects_to).to eq(database: { writing: :queue })
  end

  # Grep-based, like the live-probe example in spec/network_boundary_spec.rb: the :queue tag
  # is what swaps the adapter, so a file outside spec/queue/ carrying it would quietly start
  # writing queue rows from the middle of the ordinary suite.
  it "confines the :queue tag to spec/queue" do
    tagged = Dir[Rails.root.join("spec/**/*_spec.rb")].select do |path|
      File.read(path).match?(/^RSpec\.describe.*, :queue\b/)
    end

    expect(tagged.map { |path| Pathname(path).relative_path_from(Rails.root).to_s })
      .to all(start_with("spec/queue/"))
  end
end
