require "rails_helper"

RSpec.describe Github::UrlPolicy do
  def violations_for(url, mode: :live)
    described_class.validate(url, mode: mode).violations
  end

  describe "the canonical case" do
    it "accepts the GitHub API host over HTTPS" do
      validated = described_class.validate!("https://api.github.com/events", mode: :live)

      expect(validated.to_s).to eq("https://api.github.com/events")
    end

    # A string the validator and the HTTP client might read differently must never
    # reach a socket, and the target must not be repointable between check and request.
    it "rebuilds the URL from validated components rather than forwarding the input" do
      validated = described_class.validate!("https://API.GitHub.COM/events#fragment", mode: :live)

      expect(validated.to_s).to eq("https://api.github.com/events")
      expect(validated.uri).to be_frozen
      expect(validated).to be_frozen
    end

    it "accepts an explicit :443, which is the scheme's own default port" do
      expect(described_class.validate!("https://api.github.com/x", mode: :live).to_s)
        .to eq(described_class.validate!("https://api.github.com:443/x", mode: :live).to_s)
    end

    # Link-driven pagination depends on the query surviving intact, and enrichment on
    # already-encoded path segments surviving.
    it "preserves the query string and existing percent-encoding" do
      validated = described_class.validate!("https://api.github.com/events?per_page=100&page=2", mode: :live)
      encoded = described_class.validate!("https://api.github.com/repos/o/r%2Fx", mode: :live)

      expect(validated.query).to eq("per_page=100&page=2")
      expect(encoded.path).to eq("/repos/o/r%2Fx")
    end
  end

  describe "scheme rejections" do
    it "rejects http, because the boundary is HTTPS-only" do
      expect(violations_for("http://api.github.com/x")).to eq([ :scheme_not_allowed ])
    end

    it "rejects a scheme-relative URL, which has no scheme to trust" do
      expect(violations_for("//api.github.com/x")).to include(:not_absolute)
    end

    it "rejects schemes that would read a local file or reach another protocol" do
      %w[ file:///etc/passwd gopher://api.github.com/x ftp://api.github.com/x ].each do |url|
        expect(violations_for(url)).to include(:scheme_not_allowed), "expected #{url} to be refused"
      end
    end

    # A live deployment must never be able to address the corpus.
    it "rejects the fixture scheme while the application is in live mode" do
      expect(violations_for("fixture://api.github.com/events")).to eq([ :scheme_not_allowed ])
    end
  end

  describe "host rejections" do
    it "rejects hosts that only look like the API host" do
      %w[
        https://api.github.com.evil.test/x
        https://apigithub.com/x
        https://api.github.co/x
        https://evil.test/api.github.com
        https://raw.githubusercontent.com/x
      ].each do |url|
        expect(violations_for(url)).to eq([ :host_not_allowed ]), "expected #{url} to be refused"
      end
    end

    # DNS treats api.github.com. as equivalent, but an exact-match allowlist does not —
    # which is the whole point of comparing the canonical form.
    it "rejects a trailing-dot host" do
      expect(violations_for("https://api.github.com./events")).to eq([ :host_not_allowed ])
    end

    it "rejects a percent-encoded host that would decode to the API host" do
      expect(violations_for("https://api%2egithub%2ecom/x")).to eq([ :host_not_allowed ])
    end

    it "rejects a punycode lookalike host" do
      expect(violations_for("https://xn--pi-hia.github.com/x")).to eq([ :host_not_allowed ])
    end

    # RFC 3986 forbids non-ASCII, so a Unicode homograph never parses. Failing closed on
    # a string the parser refuses is the documented behaviour, not an accident.
    it "rejects a Unicode homograph host as unparsable" do
      expect(violations_for("https://аpi.github.com/x")).to eq([ :unparsable ])
    end

    it "rejects a URL with no host at all" do
      expect(violations_for("file:///etc/passwd")).to include(:host_missing)
    end
  end

  describe "userinfo rejections" do
    # The classic spoof. Note it is the host rule that actually refuses this one: RFC
    # 3986 puts everything before the @ in userinfo, so the host really is evil.test.
    it "rejects a URL whose userinfo makes a hostile host look like the API host" do
      expect(violations_for("https://api.github.com@evil.test/x"))
        .to contain_exactly(:userinfo_present, :host_not_allowed)
    end

    it "rejects credentials even on the allowed host, which would otherwise reach logs" do
      expect(violations_for("https://user:password@api.github.com/x")).to eq([ :userinfo_present ])
    end
  end

  describe "IP-literal rejections" do
    it "rejects an IPv4 literal, which bypasses the DNS name entirely" do
      expect(violations_for("https://140.82.121.6/x")).to eq([ :ip_literal_host ])
    end

    it "rejects loopback and cloud-metadata addresses" do
      [ "https://127.0.0.1/x", "https://169.254.169.254/latest/meta-data" ].each do |url|
        expect(violations_for(url)).to eq([ :ip_literal_host ]), "expected #{url} to be refused"
      end
    end

    it "rejects an IPv6 literal, brackets and all" do
      expect(violations_for("https://[2606:50c0::153]/x")).to eq([ :ip_literal_host ])
    end

    it "rejects an IPv4-mapped IPv6 literal" do
      expect(violations_for("https://[::ffff:140.82.121.6]/x")).to eq([ :ip_literal_host ])
    end

    # IPAddr recognises neither of these forms, so they are refused as disallowed hosts.
    # That is the honest statement of where the security comes from: the allowlist.
    it "rejects decimal and hexadecimal IPv4 forms as disallowed hosts, not as IP literals" do
      [ "https://2130706433/x", "https://0x7f000001/x" ].each do |url|
        expect(violations_for(url)).to eq([ :host_not_allowed ]), "expected #{url} to be refused"
      end
    end
  end

  describe "port rejections" do
    it "rejects any non-default port, which would allow internal port scanning" do
      [ "https://api.github.com:8443/x", "https://api.github.com:80/x", "https://api.github.com:22/x" ]
        .each do |url|
          expect(violations_for(url)).to eq([ :non_default_port ]), "expected #{url} to be refused"
        end
    end
  end

  describe "malformed and empty input" do
    it "rejects a string the parser will not accept rather than guessing at it" do
      [ "not a url", "https://api.github.com/x\\@evil.test/", "https://api.github.com/a b" ].each do |url|
        expect(violations_for(url)).to eq([ :unparsable ]), "expected #{url.inspect} to be refused"
      end
    end

    # A payload whose actor.url is missing must not become a request to nowhere.
    it "rejects nil and blank input" do
      [ nil, "", "   " ].each do |url|
        expect(violations_for(url)).to eq([ :blank ]), "expected #{url.inspect} to be refused"
      end
    end
  end

  describe "reporting" do
    it "reports every violation a URL commits, so a log names the whole reason" do
      expect(violations_for("http://user:pw@127.0.0.1:9000/x"))
        .to contain_exactly(:scheme_not_allowed, :userinfo_present, :ip_literal_host)
    end

    it "raises with the violations attached, which PR 7 branches on" do
      expect { described_class.validate!("https://evil.test/x", mode: :live) }
        .to raise_error(Github::Errors::UrlPolicyViolation) { |error|
          expect(error.violations).to eq([ :host_not_allowed ])
          expect(error.url).to eq("https://evil.test/x")
        }
    end

    # Reason drift would break PR 7's mapping onto permanent_failure.
    it "names a closed violation vocabulary" do
      expect(described_class::VIOLATIONS).to match_array(
        %i[ blank unparsable not_absolute scheme_not_allowed userinfo_present
            host_missing ip_literal_host host_not_allowed non_default_port ]
      )
    end

    it "only ever reports reasons from that vocabulary" do
      urls = [ nil, "not a url", "//x/y", "http://api.github.com", "https://u:p@api.github.com",
               "file:///x", "https://127.0.0.1", "https://evil.test", "https://api.github.com:8443" ]

      urls.each do |url|
        expect(described_class::VIOLATIONS).to include(*violations_for(url))
      end
    end
  end

  describe "the boundary itself" do
    # An environment variable here would make the SSRF boundary a deployment setting.
    it "reads the allowed host from a constant, not from the environment" do
      expect(described_class::ALLOWED_HOST).to eq("api.github.com")
      expect(Github::Configuration::DEFAULTS.keys.grep(/HOST|BASE_URL/)).to be_empty
    end

    # URI.parse consults URI::DEFAULT_PARSER, which URI.parser= can reassign from any
    # gem in the bundle — the boundary must not be movable from outside this file.
    it "pins the RFC 3986 parser rather than the reassignable default" do
      expect(described_class::PARSER).to equal(URI::RFC3986_PARSER)
      expect(URI).not_to receive(:parse)

      described_class.validate("https://api.github.com/x", mode: :live)
    end

    it "cannot be constructed outside the policy" do
      expect { Github::UrlPolicy::ValidatedUrl.new(URI("https://api.github.com"), :live) }
        .to raise_error(NoMethodError)
    end

    it "rejects an unknown mode rather than defaulting to one" do
      expect { described_class.validate("https://api.github.com", mode: :offline) }
        .to raise_error(Github::Errors::ConfigurationError, /unknown GitHub mode/)
    end
  end

  describe "fixture mode" do
    it "accepts the location an offline event source constructs" do
      validated = described_class.validate!("fixture://api.github.com/events?per_page=100", mode: :fixture)

      expect(validated.to_s).to eq("fixture://api.github.com/events?per_page=100")
      expect(validated.mode).to eq(:fixture)
    end

    it "rejects a live URL while the application is in fixture mode" do
      expect(violations_for("https://api.github.com/events", mode: :fixture)).to eq([ :scheme_not_allowed ])
    end

    it "applies the same host rule offline, so the corpus is not a wider boundary" do
      expect(violations_for("fixture://evil.test/events", mode: :fixture)).to eq([ :host_not_allowed ])
    end

    it "rejects an explicit port on a fixture location" do
      expect(violations_for("fixture://api.github.com:8080/events", mode: :fixture)).to eq([ :non_default_port ])
    end
  end

  describe ".validate_payload_url!" do
    it "returns the live URL unchanged in live mode" do
      validated = described_class.validate_payload_url!("https://api.github.com/users/octocat", mode: :live)

      expect(validated.to_s).to eq("https://api.github.com/users/octocat")
      expect(validated.mode).to eq(:live)
    end

    # This is what makes one corpus serve both transports: the payload stays realistic
    # https GitHub JSON, and the offline transport still gets an address it can resolve.
    it "projects a payload URL onto the fixture scheme so the corpus can answer it" do
      validated = described_class.validate_payload_url!("https://api.github.com/users/octocat", mode: :fixture)

      expect(validated.to_s).to eq("fixture://api.github.com/users/octocat")
      expect(validated.mode).to eq(:fixture)
    end

    it "preserves the query when projecting, so paginated targets survive" do
      validated = described_class.validate_payload_url!("https://api.github.com/events?page=2", mode: :fixture)

      expect(validated.to_s).to eq("fixture://api.github.com/events?page=2")
    end

    # Fixture mode must never be a weaker boundary than live: the precondition for
    # reaching the corpus is clearing the entire live policy first.
    it "refuses in fixture mode anything live mode would refuse" do
      [ "https://evil.test/x", "http://api.github.com/x", "https://127.0.0.1/x",
        "https://user:pw@api.github.com/x" ].each do |url|
        expect { described_class.validate_payload_url!(url, mode: :fixture) }
          .to raise_error(Github::Errors::UrlPolicyViolation), "expected #{url} to be refused offline too"
      end
    end

    # A response body must not be able to address the corpus directly.
    it "refuses a payload that supplies a fixture URL itself" do
      expect { described_class.validate_payload_url!("fixture://api.github.com/users/root", mode: :fixture) }
        .to raise_error(Github::Errors::UrlPolicyViolation, /scheme_not_allowed/)
    end
  end
end
