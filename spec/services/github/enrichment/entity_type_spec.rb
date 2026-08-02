require "rails_helper"

RSpec.describe Github::Enrichment::EntityType do
  describe ".all" do
    it "covers exactly the two entity classes, each with a detail and a search request class" do
      expect(described_class.keys).to eq(Github::Request::DETAIL_CLASSES)
      expect(described_class.all.map(&:request_class)).to eq(Github::Request::DETAIL_CLASSES)
      expect(described_class.all.map(&:search_request_class)).to eq(Github::Request::SEARCH_CLASSES)
    end

    # The two ledger-facing vocabularies must stay in lockstep: every request class the
    # budget ledgers meter for enrichment is reachable from exactly one entity type, so a
    # new class cannot be added on one side and silently go unmetered on the other.
    it "spans the ledger's enrichment classes exactly" do
      classes = described_class.all.flat_map do |type|
        [ type.request_class, type.search_request_class ]
      end

      expect(classes).to match_array(Github::Request::ENRICHMENT_CLASSES)
    end

    # The batch runner reserves under :actor_search/:repository_search (the per-minute
    # search ledger) while the detail fallback reserves under :actor/:repository (the
    # bounded core allowance). The pairing is enumerated here, once.
    it "pairs each key with its own search request class" do
      expect(described_class.fetch(:actor).search_request_class).to eq(:actor_search)
      expect(described_class.fetch(:repository).search_request_class).to eq(:repository_search)
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
