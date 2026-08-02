require "rails_helper"

RSpec.describe Github::Enrichment::SearchQuery do
  let(:actors) { Github::Enrichment::EntityType.fetch(:actor) }
  let(:repositories) { Github::Enrichment::EntityType.fetch(:repository) }

  def query_params(url)
    URI.decode_www_form(URI.parse(url).query).to_h
  end

  describe "the batch qualifier syntax" do
    # The live probe behind issue #45: `user:a OR user:b` answers HTTP 422, while
    # space-joined repeated qualifiers are the documented AND-of-qualifiers form that
    # matches each exact login. The decoded q is asserted, and the absence of OR —
    # ever — is the regression guard.
    it "joins repeated exact qualifiers with spaces, never OR" do
      url = described_class.build(actors, %w[ octocat monalisa hubot ], mode: :live)

      expect(query_params(url)["q"]).to eq("user:octocat user:monalisa user:hubot")
      expect(url).not_to include("OR")
    end

    it "uses the repo qualifier for repositories" do
      url = described_class.build(repositories, %w[ octocat/Hello-World rails/rails ], mode: :live)

      expect(query_params(url)["q"]).to eq("repo:octocat/Hello-World repo:rails/rails")
    end

    # per_page equals the batch size so the requested and returned sets are comparable
    # one-to-one — a short page is then evidence, not pagination.
    it "sets per_page to exactly the batch size" do
      url = described_class.build(actors, %w[ octocat monalisa ], mode: :live)

      expect(query_params(url)["per_page"]).to eq("2")
    end

    it "sets per_page to one for a single-entity batch" do
      url = described_class.build(actors, %w[ octocat ], mode: :live)

      expect(query_params(url)["per_page"]).to eq("1")
    end
  end

  describe "encoding" do
    # URI.encode_www_form's application/x-www-form-urlencoded rules: the qualifier
    # colon and the owner/name slash are percent-encoded, and the joining spaces
    # become `+`. What matters downstream is that the raw query component contains no
    # literal colon, slash, or space for a proxy or log line to mis-split on.
    it "percent-encodes the qualifier colon and the repository slash, and joins with +" do
      url = described_class.build(repositories, %w[ octocat/Hello-World rails/rails ], mode: :live)
      query = URI.parse(url).query

      expect(query).to eq("q=repo%3Aoctocat%2FHello-World+repo%3Arails%2Frails&per_page=2")
      expect(query).not_to include(":", "/", " ")
    end
  end

  describe "endpoints" do
    it "targets /search/users for actors" do
      url = described_class.build(actors, %w[ octocat ], mode: :live)

      expect(url).to start_with("https://api.github.com/search/users?")
    end

    it "targets /search/repositories for repositories" do
      url = described_class.build(repositories, %w[ octocat/Hello-World ], mode: :live)

      expect(url).to start_with("https://api.github.com/search/repositories?")
    end
  end

  # Mode-aware for the same reason Github::EventSources splits PublicEvents from
  # FixtureEvents: these are application-origin URLs, and Github::UrlPolicy accepts
  # only the fixture scheme in fixture mode — fail closed, never a live fallback.
  describe "mode awareness" do
    it "builds a fixture-scheme origin in fixture mode" do
      url = described_class.build(actors, %w[ octocat ], mode: :fixture)

      expect(url).to start_with("fixture://api.github.com/search/users?")
    end

    # Github::Configuration#mode is a String, and the default mode argument comes from
    # it — so the string spelling must resolve exactly like the symbol.
    it "accepts the configuration's string spelling of a mode" do
      url = described_class.build(actors, %w[ octocat ], mode: "fixture")

      expect(url).to start_with("fixture://api.github.com/")
    end

    it "refuses an unknown mode rather than defaulting to live" do
      expect { described_class.build(actors, %w[ octocat ], mode: :staging) }
        .to raise_error(ArgumentError, /staging/)
    end
  end

  # An empty batch would build `q=&per_page=0` — a request that spends a search
  # reservation to ask GitHub for nothing. The claim never produces one, so reaching
  # here with no identifiers is a programming error.
  it "refuses an empty batch" do
    expect { described_class.build(actors, [], mode: :live) }
      .to raise_error(ArgumentError, /empty/)
  end
end
