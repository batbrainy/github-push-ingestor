require "rails_helper"

RSpec.describe Github::EventSources::FixtureEvents do
  subject(:source) { described_class.new(create_event_source(source_type: described_class.source_type)) }

  let(:expected_mode) { :fixture }

  it_behaves_like "a GitHub event source"

  it "returns a deterministic fixture location, as plan §6 specifies" do
    expect(source.first_page_url).to eq("fixture://api.github.com/events?per_page=100")
  end

  # This is what makes one corpus entry answer a request from either transport: the
  # canonical key omits scheme and host because UrlPolicy has already proved them.
  it "addresses the same corpus entry as the live source's page-one URL" do
    live_key = Github::FixtureCorpus.key_for(
      Github::UrlPolicy.validate!(Github::EventSources::PublicEvents::FIRST_PAGE_URL, mode: :live)
    )
    fixture_key = Github::FixtureCorpus.key_for(
      Github::UrlPolicy.validate!(source.first_page_url, mode: :fixture)
    )

    expect(fixture_key).to eq(live_key)
    expect(corpus.responses_for(fixture_key)).to be_present
  end

  # The defect this covers: the corpus publishes real https Link targets, so building
  # them as application-origin requests made offline pagination impossible. Uses the
  # actual header the paginated scenario serves rather than a hand-written URL.
  it "reaches the next page offline from the Link header the corpus actually serves" do
    offline = Github::Transports::Fixture.new(corpus: corpus(scenario: "paginated"),
                                              clock: -> { frozen_time })
    first = offline.get(Github::UrlPolicy.validate!(source.first_page_url, mode: :fixture))
    next_url = first.header("link")[/<([^>]+)>;\s*rel="next"/, 1]

    request = source.linked_page_request(next_url)
    validated = Github::UrlPolicy.validate_payload_url!(request.url, mode: :fixture)

    expect(next_url).to start_with("https://api.github.com/")
    expect(JSON.parse(offline.get(validated).body).size).to eq(3)
  end

  # A fixture location must never be reachable from a live deployment.
  it "builds a location the live policy refuses outright" do
    expect { Github::UrlPolicy.validate!(source.first_page_url, mode: :live) }
      .to raise_error(Github::Errors::UrlPolicyViolation, /scheme_not_allowed/)
  end
end
