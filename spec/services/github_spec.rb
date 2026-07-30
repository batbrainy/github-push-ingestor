require "rails_helper"

# The composition root. CLAUDE.md's rule — every live GitHub request goes through
# request gate -> ledger -> URL policy -> transport, and nothing outside that chain
# calls GitHub — only holds if there is one place that assembles the chain.
RSpec.describe Github do
  after { described_class.reset! }

  describe ".configuration" do
    it "reads the environment once per process" do
      expect(described_class.configuration).to equal(described_class.configuration)
    end
  end

  describe ".transport" do
    it "selects the live transport in live mode" do
      expect(described_class.transport).to be_a(Github::Transports::Faraday)
    end

    it "selects the offline transport in fixture mode" do
      allow(described_class).to receive(:configuration).and_return(
        Github::Configuration.new("GITHUB_MODE" => "fixture")
      )

      expect(described_class.transport).to be_a(Github::Transports::Fixture)
    end

    # The fixture transport's scripted sequences advance across requests, so a fresh
    # instance per call would restart every script; the live transport would rebuild its
    # Faraday connection each time.
    it "is memoised, so a scripted sequence advances instead of restarting" do
      expect(described_class.transport).to equal(described_class.transport)
    end
  end

  describe ".executor" do
    it "is the assembled chain, memoised per process" do
      expect(described_class.executor).to be_a(Github::RequestExecutor)
      expect(described_class.executor).to equal(described_class.executor)
    end
  end

  describe ".reset!" do
    # config/initializers/github.rb calls this on every reload, so a development edit to
    # GITHUB_MODE or a budget knob takes effect without a restart.
    it "drops every memoised object, including the corpus cache" do
      before_reset = described_class.configuration
      described_class.reset!

      expect(described_class.configuration).not_to equal(before_reset)
    end
  end

  describe "the boot-time contract" do
    it "validates the configuration the initializer will validate" do
      expect { described_class.configuration.validate! }.not_to raise_error
    end
  end
end
