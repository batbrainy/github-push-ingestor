# Both transports answer the same questions, so the questions live here once.
#
# The host group must provide:
#   transport      the subject
#   ok_url         a ValidatedUrl in the transport's own mode that answers 200
#   redirect_url   a ValidatedUrl whose response is a 301 carrying Location
#   other_mode_url a ValidatedUrl built for the other transport's mode
RSpec.shared_examples "a GitHub transport" do
  it "returns the status and the body exactly as received" do
    response = transport.get(ok_url)

    expect(response.status).to eq(200)
    expect(JSON.parse(response.body)).to be_a(Array).or be_a(Hash)
  end

  # §7 retains the raw payload, and PR 5's malformed-event taxonomy has to tell "this
  # body is not JSON" apart from "this event is malformed". A JSON middleware would
  # erase both.
  it "leaves the body unparsed, so the raw payload survives to persistence" do
    expect(transport.get(ok_url).body).to be_a(String)
  end

  # GitHub is not consistent about header casing, and the ledger reads these by name.
  it "downcases response header names, so no caller has to guess at casing" do
    expect(transport.get(ok_url).headers.keys).to all(satisfy { |name| name == name.downcase })
  end

  it "reports the URL it was given, so a caller can log what was actually fetched" do
    expect(transport.get(ok_url).url).to eq(ok_url)
  end

  # Every hop is the executor's to gate, reserve, and re-validate (§10).
  it "returns a redirect without following it" do
    response = transport.get(redirect_url)

    expect(response.status).to eq(301)
    expect(response.header("location")).to be_present
  end

  # The only way to obtain a ValidatedUrl is through Github::UrlPolicy, so this is what
  # makes the SSRF boundary unbypassable rather than merely conventional.
  it "refuses a bare String, so nothing reaches a transport without passing UrlPolicy" do
    expect { transport.get("https://api.github.com/events") }.to raise_error(ArgumentError)
  end

  it "refuses a URL validated for the other mode, so a corpus response is never served live" do
    expect { transport.get(other_mode_url) }.to raise_error(ArgumentError)
  end

  it "sends the three protocol headers plan §2A pins" do
    transport.get(ok_url)

    expect(sent_request_headers).to include(
      "accept" => "application/vnd.github+json",
      "x-github-api-version" => "2022-11-28",
      "user-agent" => "github-push-ingestor"
    )
  end
end
