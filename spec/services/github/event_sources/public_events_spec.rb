require "rails_helper"

RSpec.describe Github::EventSources::PublicEvents do
  subject(:source) { described_class.new(create_event_source(source_type: described_class.source_type)) }

  let(:expected_mode) { :live }

  it_behaves_like "a GitHub event source"

  it "requests the public events endpoint plan §6 names" do
    expect(source.first_page_url).to eq("https://api.github.com/events?per_page=100")
  end

  # §9: request per_page=100 and follow the Link header for subsequent pages.
  it "requests a full page, because pagination is Link-driven rather than URL-built" do
    expect(described_class::PER_PAGE).to eq(100)
  end

  it "serves the source_type its event_sources rows carry" do
    expect(described_class.source_type).to eq("github_public_events")
  end
end
