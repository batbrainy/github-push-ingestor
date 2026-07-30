require "ipaddr"

module Github
  # The SSRF trust boundary (IMPLEMENTATION_PLAN.md §10). Enrichment follows URLs that
  # arrive inside GitHub event payloads, and pagination follows URLs from Link headers,
  # so nothing is fetched that this module has not rebuilt itself.
  #
  # Three properties do the work:
  #
  #   1. The parser is pinned. URI.parse consults URI::DEFAULT_PARSER, which any gem in
  #      the bundle can reassign through URI.parser=; RFC3986_PARSER is referenced
  #      directly so the boundary cannot be moved from outside this file. Addressable
  #      was rejected for a second reason beyond not being in §2A's stack: it
  #      *normalises* — IDN to punycode, percent-decoding — which is precisely the
  #      helpful transformation you do not want at a trust boundary, because the
  #      validator and the HTTP client then disagree about what the string meant.
  #   2. Nothing the caller supplied is forwarded. A validated URL is rebuilt from the
  #      components that passed, so a string the validator and the client might read
  #      differently never reaches a socket, and the target cannot be repointed between
  #      the check and the request.
  #   3. Transports accept only a ValidatedUrl, whose constructor is private here.
  #
  # Two things worth stating plainly, because the code reads as if they were reversed:
  #
  #   * https://api.github.com@evil.com/ is already refused by the *host* rule. RFC 3986
  #     puts the part before the @ in userinfo, so the host really is evil.com. The
  #     userinfo rule exists for user:pw@api.github.com.
  #   * It is the exact-host allowlist, not the IP detector, that makes 2130706433 and
  #     0x7f000001 safe — IPAddr does not recognise either form. The IP check exists so
  #     the log names the right reason, not to provide the security.
  module UrlPolicy
    PARSER = URI::RFC3986_PARSER

    # Deliberately not environment-configurable: an env var here would turn the SSRF
    # boundary into a deployment setting.
    ALLOWED_HOST = "api.github.com"

    # The fixture scheme is an addressing detail of the offline transport, never
    # something a payload says. Its port is nil because a non-HTTP scheme has no
    # default, and any explicit port on it is therefore a violation too.
    MODES = {
      live: { scheme: "https", uri_class: URI::HTTPS, default_port: 443 }.freeze,
      fixture: { scheme: "fixture", uri_class: URI::Generic, default_port: nil }.freeze
    }.freeze

    # Closed on purpose: PR 7 maps these onto entity outcomes, and a silently added
    # reason would fall through its branch.
    VIOLATIONS = %i[
      blank unparsable not_absolute scheme_not_allowed userinfo_present
      host_missing ip_literal_host host_not_allowed non_default_port
    ].freeze

    # A URL that passed. Rebuilt rather than copied, and frozen, so nothing can move
    # the target between the check and the request.
    class ValidatedUrl
      attr_reader :uri, :mode

      def initialize(uri, mode)
        @uri = uri
        @mode = mode
        freeze
      end
      private_class_method :new

      def to_s = uri.to_s
      def path = uri.path
      def query = uri.query
      def host = uri.host
      def ==(other) = other.is_a?(ValidatedUrl) && other.uri == uri && other.mode == mode
      alias_method :eql?, :==
      def hash = [ uri, mode ].hash
    end

    Result = Data.define(:input, :url, :violations) do
      def allowed? = violations.empty?
    end

    class << self
      # A location the application constructed itself: an event source's own endpoint.
      # Validated directly against the given mode.
      #
      # @return [Github::UrlPolicy::ValidatedUrl]
      # @raise [Github::Errors::UrlPolicyViolation]
      def validate!(url, mode:)
        result = validate(url, mode: mode)
        raise Errors::UrlPolicyViolation.new(url, result.violations) unless result.allowed?

        result.url
      end

      # A URL that arrived inside a GitHub payload or a Link header — one an attacker
      # could influence. Always validated against the *live* policy first, whatever the
      # mode. In fixture mode the components that passed are then rebuilt under the
      # fixture scheme, so reaching the corpus requires clearing the full live policy:
      # a payload cannot forge a corpus address, and a hostile https URL cannot become
      # a fixture URL. Fixture mode is therefore never a weaker boundary than live.
      #
      # @return [Github::UrlPolicy::ValidatedUrl]
      # @raise [Github::Errors::UrlPolicyViolation]
      def validate_payload_url!(url, mode:)
        live = validate!(url, mode: :live)
        return live if mode.to_sym == :live

        ValidatedUrl.send(:new, rebuild(live.uri, MODES.fetch(:fixture)), :fixture)
      end

      def validate(url, mode:)
        spec = MODES.fetch(mode.to_sym) do
          raise Errors::ConfigurationError, "unknown GitHub mode #{mode.inspect}"
        end

        input = url.is_a?(URI::Generic) ? url.to_s : url.to_s
        return failure(input, [ :blank ]) if input.strip.empty?

        uri = parse(input) { |reason| return failure(input, [ reason ]) }

        violations = []
        violations.concat(scheme_violations(uri, spec))
        violations << :userinfo_present if uri.userinfo.present?
        violations.concat(host_violations(uri))
        return failure(input, violations) if violations.any?

        Result.new(input: input, url: ValidatedUrl.send(:new, rebuild(uri, spec), mode.to_sym),
                   violations: [].freeze)
      end

      private

      # A parse failure short-circuits, because nothing else about the URL is knowable.
      # Non-ASCII hosts (Unicode homographs), control characters, raw spaces and
      # backslashes all land here under RFC 3986 — failing closed on a string the
      # parser will not accept is the point, since nothing downstream then gets a
      # second opinion about what it meant.
      def parse(input)
        PARSER.parse(input)
      rescue URI::InvalidURIError, URI::InvalidComponentError, ArgumentError
        yield :unparsable
      end

      def scheme_violations(uri, spec)
        return [ :not_absolute ] if uri.scheme.nil?
        return [ :scheme_not_allowed ] unless uri.scheme.downcase == spec[:scheme]
        # Only meaningful once the scheme is known, which is why it is nested here
        # rather than checked independently.
        return [ :non_default_port ] unless uri.port == spec[:default_port]

        []
      end

      def host_violations(uri)
        # #hostname, not #host: an IPv6 literal carries its brackets in #host and would
        # not be recognised as an address.
        host = uri.hostname
        return [ :host_missing ] if host.nil? || host.empty?
        return [ :ip_literal_host ] if ip_literal?(host)
        return [ :host_not_allowed ] unless host.downcase == ALLOWED_HOST

        []
      end

      def ip_literal?(host)
        IPAddr.new(host)
        true
      rescue IPAddr::InvalidAddressError
        false
      end

      # Rebuilt from validated components. Userinfo is gone (already refused), an
      # explicit default port is gone, the fragment is gone — it is never sent on the
      # wire — and the host is case-folded, so one canonical request form exists
      # regardless of how the payload spelled it.
      def rebuild(uri, spec)
        spec[:uri_class].build(
          scheme: spec[:scheme],
          host: uri.hostname.downcase,
          path: uri.path.to_s.empty? ? "/" : uri.path,
          query: uri.query
        ).freeze
      end

      def failure(input, violations)
        Result.new(input: input, url: nil, violations: violations.uniq.freeze)
      end
    end
  end
end
