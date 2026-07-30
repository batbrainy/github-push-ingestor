# The event-source adapter contract (plan §6, Story 1 child 2). Both implementations
# answer the same questions, which is what stops the seam being speculative.
#
# The host group must provide:
#   source            an adapter instance
#   expected_mode     the Github::UrlPolicy mode its page-one URL is valid in
RSpec.shared_examples "a GitHub event source" do
  it "declares the event_sources.source_type it serves" do
    expect(source.source_type).to be_a(String).and be_present
  end

  # §9 scopes the persisted ETag to exactly this URL with its stable query parameters,
  # so a URL that varied between polls could never match.
  it "declares a page-one URL that includes its stable query parameters" do
    expect(source.first_page_url).to include("per_page=100")
  end

  it "builds a request the URL policy accepts in its own mode" do
    expect { Github::UrlPolicy.validate!(source.first_page_url, mode: expected_mode) }.not_to raise_error
  end

  # §7: polling is one budget class whatever source issued the request.
  it "builds requests that debit the poll allowance" do
    expect(source.first_page_request.request_class).to eq(:poll)
  end

  # The source's own endpoint is not attacker-influenced, which is what lets the offline
  # source address the corpus with a scheme no payload could ever supply.
  it "marks its own endpoint as application-constructed rather than payload-supplied" do
    expect(source.first_page_request).not_to be_payload_supplied
  end

  it "sends no conditional header when the source has no stored ETag" do
    expect(source.first_page_request.headers).not_to have_key("If-None-Match")
  end

  it "sends the stored ETag when it is given one" do
    expect(source.first_page_request(etag: 'W/"abc"').headers).to include("If-None-Match" => 'W/"abc"')
  end

  # The pagination seam: PR 6 calls this with a URL from a Link header, and one
  # primitive serves both without a contract change.
  it "builds a request for any URL it is handed, which is how PR 6 will paginate" do
    request = source.request_for("#{source.first_page_url}&page=2")

    expect(request.url).to end_with("page=2")
    expect(request.request_class).to eq(:poll)
  end

  # A Link target is a URL GitHub supplied, so it has to clear the live policy and then
  # be projected — an application-origin request built from one is refused as
  # scheme_not_allowed offline, which would make Link-driven pagination impossible
  # through this contract.
  it "marks a Link target as payload-supplied, so it survives the URL policy in either mode" do
    link_target = "https://api.github.com/events?per_page=100&page=2"
    request = source.linked_page_request(link_target)

    expect(request).to be_payload_supplied
    expect { Github::UrlPolicy.validate_payload_url!(request.url, mode: expected_mode) }
      .not_to raise_error
  end

  # §11's correlation fields. Request#to_log merges context flat and FetchResult#to_log
  # merges request.to_log, so a caller's run_id reaches the DEBUG github.request line
  # without the executor or the formatter knowing about it.
  it "carries a caller's correlation context onto the request's log line" do
    request = source.first_page_request(context: { run_id: "2f5b9c3e" })

    expect(request.to_log).to include(run_id: "2f5b9c3e", source_type: source.source_type)
  end

  it "will not let a caller's context overwrite the source type it reports" do
    request = source.first_page_request(context: { source_type: "impersonated" })

    expect(request.to_log[:source_type]).to eq(source.source_type)
  end

  it "decodes a fetched page into raw event envelopes, untouched" do
    events = source.events(fetch_result_with('[{"id":"1","type":"PushEvent"},null]'))

    expect(events).to eq([ { "id" => "1", "type" => "PushEvent" }, nil ])
  end

  # PR 5 tells a malformed *event* from a malformed *response*; the taxonomy needs both
  # to be distinguishable, so a body that is not an array is a response-level failure.
  it "refuses a body that is not a JSON array" do
    expect { source.events(fetch_result_with('{"message":"Not Found"}')) }
      .to raise_error(Github::Errors::MalformedResponse)
  end

  it "refuses a body that is not JSON at all" do
    expect { source.events(fetch_result_with("<html>502</html>")) }
      .to raise_error(Github::Errors::MalformedResponse, /not valid JSON/)
  end

  def fetch_result_with(body)
    Github::FetchResult.from_response(
      request: source.first_page_request, status: 200, headers: {}, body: body, duration_ms: 1.0
    )
  end
end
