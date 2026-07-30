module Github
  module Transports
    # Resolves every request inside the static corpus (IMPLEMENTATION_PLAN.md §6, §12).
    # There is no socket here and no live fallback: an unknown URL raises, so fixture
    # mode fails closed rather than quietly reaching GitHub.
    #
    # Fixture mode still takes the request gate, still reserves budget, still passes the
    # URL policy, and still reconciles the corpus's rate-limit headers. §12's "zero live
    # quota consumed" means zero *GitHub* quota, not zero accounting — the corpus's
    # x-ratelimit-* headers are exactly what make the per-window bootstrap runnable
    # offline. That is the difference between a fixture mode that proves the
    # architecture and one that bypasses it.
    class Fixture
      MODE = :fixture

      # A header value of "+N" resolves to N seconds from now, in epoch seconds.
      #
      # x-ratelimit-reset needs this. A fixed epoch in the corpus is in the past by the
      # time anyone runs the demo, and the ledger then correctly rolls the window on
      # every single poll — so counters never accumulate and fixture mode stops
      # demonstrating the accounting it exists to demonstrate. Bodies stay byte-static;
      # only this one header shape is relative, and the clock is injectable so specs
      # stay deterministic.
      RELATIVE_SECONDS = /\A\+(\d+)\z/

      # Cursors live on the instance, never at class level, so two transports never
      # share a script position and one spec cannot advance another's sequence under
      # random ordering.
      def initialize(corpus: FixtureCorpus.load, clock: -> { Time.current })
        @corpus = corpus
        @clock = clock
        @cursors = Hash.new(0)
        @requests = []
        @mutex = Mutex.new
      end

      attr_reader :corpus, :requests

      # @param validated_url [Github::UrlPolicy::ValidatedUrl]
      # @return [Github::Transports::Response]
      # @raise [Github::Errors::FixtureMiss] for a URL the corpus does not define
      def get(validated_url, headers: {})
        assert_usable!(validated_url)
        key = corpus.key_for(validated_url)

        @mutex.synchronize do
          # Recorded so a spec can assert what was actually sent — which is how the
          # conditional-request path is tested without the corpus having to match on
          # If-None-Match.
          @requests << { method: :get, key: key, url: validated_url.to_s, headers: sent_headers(headers) }

          scripted = corpus.responses_for(key)
          raise Errors::FixtureMiss, "the corpus defines no response for #{key.inspect}" if scripted.nil?

          # Sticky tail: the last scripted response repeats forever, so a long-running
          # fixture container has defined behaviour rather than an eventual error.
          index = [ @cursors[key], scripted.length - 1 ].min
          @cursors[key] += 1

          scripted.fetch(index).then do |response|
            Response.new(status: response.status, headers: resolve(response.headers),
                         body: response.body, url: validated_url, duration_ms: 0.0)
          end
        end
      end

      private

      def resolve(headers)
        headers.to_h do |name, value|
          relative = RELATIVE_SECONDS.match(value)
          [ name, relative ? (@clock.call.to_i + relative[1].to_i).to_s : value ]
        end.freeze
      end

      def assert_usable!(validated_url)
        return if validated_url.is_a?(UrlPolicy::ValidatedUrl) && validated_url.mode == MODE

        raise ArgumentError, "the fixture transport accepts only a fixture Github::UrlPolicy::ValidatedUrl"
      end

      # Mirrors the live transport, which applies the pinned protocol headers as
      # connection defaults — otherwise a header assertion would pass offline and fail
      # against the real API.
      def sent_headers(headers)
        Request::PROTOCOL_HEADERS.merge(headers).transform_keys { |name| name.to_s.downcase }.freeze
      end
    end
  end
end
