module Github
  module Transports
    # The only place in this application that opens a socket.
    #
    # NOTE the leading :: on every gem reference below. Inside module Github::Transports
    # the bare constant `Faraday` resolves to this class, because Ruby walks
    # Module.nesting before Object. The class name is pinned by plan §5, so the guard is
    # the leading :: plus a spec asserting the connection really is a ::Faraday::Connection.
    #
    # The connection carries the adapter and nothing else. That is the decision recorded
    # in docs/adr/0003:
    #
    #   faraday-retry            retries inside one connection call — beneath the request
    #                            gate and beneath the ledger. §10 requires every attempt
    #                            to re-reserve budget, and §2A puts exactly one request
    #                            inside the gate, so a middleware retry would also sleep
    #                            while holding a session advisory lock.
    #   faraday-follow_redirects follows Location without re-entering Github::UrlPolicy,
    #                            which is the SSRF boundary (§10).
    #   Response::RaiseError     turns 304, 403 and 404 into exceptions, and every one of
    #                            those is a status this application classifies.
    #   a JSON response parser   discards the raw body, which §7 retains and which PR 5's
    #                            malformed-event taxonomy needs in order to tell "this
    #                            body is not JSON" from "this event is malformed".
    #
    # No base url: is set either. Requests carry an absolute validated URI, so there is
    # no relative-resolution path away from the allowed host.
    class Faraday
      MODE = :live

      def initialize(open_timeout: Github.configuration.http_open_timeout_seconds,
                     read_timeout: Github.configuration.http_read_timeout_seconds)
        @open_timeout = open_timeout
        @read_timeout = read_timeout
      end

      # @param validated_url [Github::UrlPolicy::ValidatedUrl]
      # @return [Github::Transports::Response]
      # @raise [Github::Errors::TransportError] when no status could be obtained
      def get(validated_url, headers: {})
        assert_usable!(validated_url)
        started = monotonic_now

        response = connection.get(validated_url.uri) do |request|
          headers.each { |name, value| request.headers[name] = value }
        end

        Response.new(
          status: response.status,
          headers: Response.normalize(response.headers),
          body: response.body.to_s,
          url: validated_url,
          duration_ms: elapsed_ms(started)
        )
      rescue ::Faraday::SSLError => e
        # Rescued before ConnectionFailed, which it subclasses in some Faraday versions.
        raise Errors::TlsError, e.message
      rescue ::Faraday::TimeoutError => e
        raise Errors::RequestTimeout, e.message
      rescue ::Faraday::ConnectionFailed => e
        raise Errors::ConnectionFailed, e.message
      rescue ::Faraday::Error => e
        raise Errors::TransportError, e.message
      end

      def connection
        @connection ||= ::Faraday.new(
          headers: Request::PROTOCOL_HEADERS.dup,
          ssl: { verify: true, min_version: :TLS1_2 },
          request: { open_timeout: @open_timeout, timeout: @read_timeout }
        ) { |faraday| faraday.adapter :net_http }
      end

      private

      # A String never works here. The only way to obtain a ValidatedUrl is through
      # Github::UrlPolicy, so nothing can reach a socket without passing the SSRF
      # boundary first, and a fixture-mode URL can never be served live.
      def assert_usable!(validated_url)
        return if validated_url.is_a?(UrlPolicy::ValidatedUrl) && validated_url.mode == MODE

        raise ArgumentError, "the live transport accepts only a live Github::UrlPolicy::ValidatedUrl"
      end

      def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      def elapsed_ms(started) = ((monotonic_now - started) * 1000).round(1)
    end
  end
end
