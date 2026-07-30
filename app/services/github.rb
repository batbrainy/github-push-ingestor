# The composition root for everything that talks to GitHub.
#
# CLAUDE.md and IMPLEMENTATION_PLAN.md §5 state the rule this namespace exists to
# enforce: every live GitHub request — polling and enrichment, from the poller, the
# worker, or the one-shot — goes through
#
#   request gate -> budget ledger reservation -> URL policy -> transport
#
# and nothing outside that chain ever calls GitHub. The source lock sits *outside*
# the chain: IngestionRunner (PR 5) holds it around a whole polling operation, and
# enrichment never takes one.
#
# Configuration is memoised per process and cleared by config/initializers/github.rb
# on every reload, so a development edit takes effect without a restart while a
# production process reads the environment exactly once.
module Github
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    # Memoised per process. The fixture transport's scripted sequences advance across
    # requests, so a fresh transport per call would restart every script; the live
    # transport would rebuild its Faraday connection each time.
    def transport
      @transport ||= configuration.fixture? ? Transports::Fixture.new : Transports::Faraday.new
    end

    def executor
      @executor ||= RequestExecutor.new(transport: transport)
    end

    def reset!
      @configuration = nil
      @transport = nil
      @executor = nil
      FixtureCorpus.reset!
    end
  end
end
