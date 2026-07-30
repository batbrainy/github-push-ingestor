require "rails_helper"

RSpec.describe Github::Transports::Faraday do
  subject(:transport) { described_class.new(open_timeout: 5, read_timeout: 15) }

  let(:ok_url) { live_url("/events?per_page=100") }
  let(:other_mode_url) { fixture_url("/events?per_page=100") }
  let(:redirect_url) { live_url("/repos/octocat/Hello-World") }

  before do
    stub_corpus!
    stub_request(:get, "https://api.github.com/repos/octocat/Hello-World")
      .to_return(status: 301, headers: { "Location" => "https://api.github.com/repos/octocat/renamed" })
  end

  def sent_request_headers
    WebMock::RequestRegistry.instance.requested_signatures.hash.keys.last.headers.transform_keys(&:downcase)
  end

  it_behaves_like "a GitHub transport"

  describe "protocol headers (plan §2A)" do
    it "sends the media type GitHub recommends" do
      transport.get(ok_url)

      expect(WebMock).to have_requested(:get, %r{api\.github\.com})
        .with(headers: { "Accept" => "application/vnd.github+json" })
    end

    # Pinned to the version every live probe behind this plan was run under; a silent
    # upgrade would change payload shape without re-verifying it.
    it "sends the pinned API version" do
      transport.get(ok_url)

      expect(WebMock).to have_requested(:get, %r{api\.github\.com})
        .with(headers: { "X-GitHub-Api-Version" => "2022-11-28" })
    end

    # GitHub rejects requests without a valid User-Agent.
    it "sends the User-Agent GitHub requires" do
      transport.get(ok_url)

      expect(WebMock).to have_requested(:get, %r{api\.github\.com})
        .with(headers: { "User-Agent" => "github-push-ingestor" })
    end

    it "carries a caller's conditional header through" do
      transport.get(ok_url, headers: { "If-None-Match" => 'W/"abc"' })

      expect(WebMock).to have_requested(:get, %r{api\.github\.com})
        .with(headers: { "If-None-Match" => 'W/"abc"' })
    end
  end

  describe "the connection" do
    it "really is a Faraday connection, despite this class shadowing the constant" do
      expect(transport.connection).to be_a(::Faraday::Connection)
    end

    # The single highest-value regression test in this PR. Adding faraday-retry would
    # retry beneath the request gate and beneath the ledger, breaking both §10's
    # "each attempt is a reservation" and §2A's one-request-per-gate-hold rule;
    # follow_redirects would bypass the SSRF boundary; RaiseError would turn statuses
    # this application classifies into exceptions; a JSON parser would discard the raw
    # body §7 retains.
    it "carries the adapter and no middleware at all" do
      expect(transport.connection.builder.handlers).to be_empty
    end

    it "applies the configured open and read timeouts, so a hung socket cannot stall the gate" do
      expect(transport.connection.options.open_timeout).to eq(5)
      expect(transport.connection.options.timeout).to eq(15)
    end

    # Nothing may be resolved relative to a base, or `//evil.test/x` could escape it.
    it "sets no base URL, so there is no relative-resolution path off the allowed host" do
      expect(transport.connection.url_prefix.to_s).to eq("http:/")
    end
  end

  describe "statuses are responses, not exceptions" do
    # Classification would never run if the client raised first.
    it "returns a 4xx as an ordinary response" do
      stub_request(:get, "https://api.github.com/users/nobody").to_return(status: 404, body: "{}")

      expect(transport.get(live_url("/users/nobody")).status).to eq(404)
    end

    it "returns a 5xx as an ordinary response" do
      stub_request(:get, "https://api.github.com/users/nobody").to_return(status: 500, body: "{}")

      expect(transport.get(live_url("/users/nobody")).status).to eq(500)
    end

    # §10's corrected accounting depends on the 304 reaching the ledger as a spent
    # request rather than as an error.
    it "returns a 304 as an ordinary response, so its reservation stays debited" do
      transport.get(ok_url)

      expect(transport.get(ok_url).status).to eq(304)
    end
  end

  describe "transport failures" do
    it "maps a read timeout to a retryable request timeout" do
      stub_request(:get, "https://api.github.com/users/nobody").to_raise(::Faraday::TimeoutError)

      expect { transport.get(live_url("/users/nobody")) }.to raise_error(Github::Errors::RequestTimeout)
    end

    # WebMock's to_timeout surfaces as Net::OpenTimeout, which Faraday's net_http adapter
    # reports as a connection failure rather than a read timeout. Both are §10's
    # "network timeout" and both are retryable, so the distinction only affects which
    # error class a log line names.
    it "maps a connection-level timeout to a retryable connection failure" do
      stub_request(:get, "https://api.github.com/users/nobody").to_timeout

      expect { transport.get(live_url("/users/nobody")) }.to raise_error(Github::Errors::ConnectionFailed)
    end

    it "makes both network-level failures retryable, as plan §10 requires" do
      [ Github::Errors::RequestTimeout, Github::Errors::ConnectionFailed ].each do |klass|
        expect(Github::RetryPolicy.disposition(klass.new)).to eq(:retry)
      end
    end

    # Not retryable: §10 lists only 5xx and network timeouts, a certificate problem will
    # not clear inside two attempts, and each retry spends quota polling needs.
    it "maps a TLS failure to an error the retry policy refuses to retry" do
      stub_request(:get, "https://api.github.com/users/nobody").to_raise(::Faraday::SSLError)

      expect { transport.get(live_url("/users/nobody")) }.to raise_error(Github::Errors::TlsError)
      expect(Github::RetryPolicy.disposition(Github::Errors::TlsError.new)).to eq(:permanent)
    end
  end

  # The guarantee CLAUDE.md states, at the one place that could break it.
  it "cannot reach a URL the suite has not stubbed" do
    expect { transport.get(live_url("/users/unstubbed")) }
      .to raise_error(WebMock::NetConnectNotAllowedError)
  end
end
