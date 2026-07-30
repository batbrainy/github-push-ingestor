require "rails_helper"

RSpec.describe Github::Enrichment::EntityType do
  describe ".all" do
    it "covers exactly the two classes the ledger has enrichment counters for" do
      expect(described_class.keys).to eq(Github::Request::ENRICHMENT_CLASSES)
    end

    it "maps each key to its own model, parser and log field" do
      expect(described_class.all.map(&:model)).to contain_exactly(GithubActor, GithubRepository)
      expect(described_class.all.map(&:document))
        .to contain_exactly(Github::Enrichment::ActorDocument, Github::Enrichment::RepositoryDocument)
      expect(described_class.all.map(&:log_key)).to contain_exactly(:github_actor_id, :github_repository_id)
    end

    # §11's common fields name github actor and repository ids, and PageWriter already logs
    # them under those keys — so an enrichment line correlates with the ingest line that
    # created the stub.
    it "uses the same log keys the ingest path already writes" do
      expect(described_class.fetch(:actor).log_key).to eq(:github_actor_id)
    end

    it "orders actor before repository, which is the fairness tie-break" do
      expect(described_class.all.map(&:key)).to eq(%i[ actor repository ])
    end
  end

  describe ".fetch" do
    it "resolves a symbol, a string, and the model class a job would hand it" do
      expect(described_class.fetch(:actor).key).to eq(:actor)
      expect(described_class.fetch("repository").key).to eq(:repository)
      expect(described_class.fetch(GithubActor).key).to eq(:actor)
    end

    it "returns an entity type it is handed, so a caller can pass either" do
      type = described_class.fetch(:actor)

      expect(described_class.fetch(type)).to equal(type)
    end

    it "refuses an unknown class rather than silently enriching nothing" do
      expect { described_class.fetch(:organization) }.to raise_error(ArgumentError, /organization/)
    end
  end

  describe "#refresh_ttl_seconds" do
    it "reads each class's own TTL through the configuration" do
      configuration = configuration_with(ACTOR_REFRESH_TTL_SECONDS: "60",
                                         REPOSITORY_REFRESH_TTL_SECONDS: "120")

      expect(described_class.fetch(:actor).refresh_ttl_seconds(configuration)).to eq(60)
      expect(described_class.fetch(:repository).refresh_ttl_seconds(configuration)).to eq(120)
    end
  end
end
