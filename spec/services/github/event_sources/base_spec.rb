require "rails_helper"

RSpec.describe Github::EventSources::Base do
  describe ".for" do
    it "resolves an adapter from the row's source_type" do
      source = create_event_source(source_type: "github_public_events")

      expect(described_class.for(source)).to be_a(Github::EventSources::PublicEvents)
    end

    it "resolves the offline adapter the same way" do
      source = create_event_source(source_type: "github_fixture_events")

      expect(described_class.for(source)).to be_a(Github::EventSources::FixtureEvents)
    end

    # §6 requires configured types to be validated against implemented adapters and to
    # fail fast with a clear configuration error rather than polling nothing.
    it "fails fast on a source_type no adapter implements, naming the ones that exist" do
      source = create_event_source(source_type: "gitlab_events")

      expect { described_class.for(source) }
        .to raise_error(Github::Errors::ConfigurationError, /gitlab_events.*github_fixture_events/m)
    end
  end

  describe ".for_mode" do
    it "maps each mode to the adapter a process in it polls with" do
      expect(described_class.for_mode(:live)).to eq(Github::EventSources::PublicEvents)
      expect(described_class.for_mode(:fixture)).to eq(Github::EventSources::FixtureEvents)
    end
  end

  describe "the abstract contract" do
    it "refuses to be used directly, because it declares no endpoint" do
      expect { described_class.new.first_page_url }.to raise_error(NotImplementedError)
      expect { described_class.source_type }.to raise_error(NotImplementedError)
    end
  end

  # §5, §6: RepositoryEvents (GET /repos/{owner}/{repo}/events) is a documented seam that
  # is deliberately not built. Adding it needs no change to this contract.
  it "ships exactly the two adapters plan §6 requires, and no speculative third" do
    expect(described_class.registry.keys).to contain_exactly("github_public_events", "github_fixture_events")
  end
end
