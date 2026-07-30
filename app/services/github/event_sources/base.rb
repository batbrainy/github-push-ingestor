module Github
  module EventSources
    # The event-source adapter contract (IMPLEMENTATION_PLAN.md §6, Story 1 child 2).
    # It isolates endpoint construction and source-specific state from common event
    # processing, and it ships with two implementations so the seam is exercised rather
    # than speculative (§6, and Appendix A item 7, which upheld the design against a
    # speculation critique on exactly that condition).
    #
    # It deliberately knows nothing about:
    #
    #   * PushEvent filtering and normalisation, or the processor registry — PR 5. This
    #     returns raw event envelopes and nothing more.
    #   * Link-header pagination — PR 6. The seam is #request_for, which builds a
    #     request for *any* URL, with #linked_page_request naming the Link case so its
    #     payload origin is not something a caller has to remember. PR 4 exercises both
    #     against the corpus, so neither is an abstract method without a caller, and PR 6
    #     adds the Link *parsing* without a contract change.
    #   * ETag persistence and 304 scheduling — PR 6. #first_page_request accepts an
    #     etag: because the corpus contains a scripted "304 with ETag" scenario (§12)
    #     that cannot be authored without conditional-header construction, but nothing
    #     in PR 4 reads or writes event_sources.etag.
    #
    # Github::EventSources::RepositoryEvents (GET /repos/{owner}/{repo}/events) is a
    # documented seam that is deliberately not built (§5, §6). Adding it needs no change
    # here: a subclass declaring its own source_type and first_page_url is the whole job,
    # and §10's allowance formula already carries ENABLED_LIVE_SOURCE_COUNT.
    class Base
      # Polling is one budget class regardless of which source issued it (§7).
      REQUEST_CLASS = :poll

      class << self
        # @return [String] the event_sources.source_type value this adapter serves
        def source_type
          raise NotImplementedError, "#{name} must declare the source_type it serves"
        end

        def registry
          @registry ||= { PublicEvents.source_type => PublicEvents,
                          FixtureEvents.source_type => FixtureEvents }.freeze
        end

        # @raise [Github::Errors::ConfigurationError] on an unimplemented source type
        def for(event_source)
          adapter = registry[event_source.source_type]
          if adapter.nil?
            raise Errors::ConfigurationError,
                  "no event source adapter implements #{event_source.source_type.inspect}; " \
                  "known types: #{registry.keys.sort.join(", ")}"
          end

          adapter.new(event_source)
        end

        # Which adapter a process in this mode polls with. PR 5's runner uses it to
        # provision the event_sources row; PR 4 only states the mapping.
        def for_mode(mode)
          mode.to_sym == :fixture ? FixtureEvents : PublicEvents
        end
      end

      def initialize(event_source = nil)
        @event_source = event_source
      end

      attr_reader :event_source

      # The canonical page-one URL, including its stable query parameters. Stability
      # matters because the persisted ETag is scoped to exactly this URL (§9).
      #
      # @return [String]
      def first_page_url
        raise NotImplementedError, "#{self.class.name} must declare its page-one URL"
      end

      def source_type
        self.class.source_type
      end

      # PR 6 calls this with a URL extracted from a Link header, which GitHub supplied
      # and which therefore has to be validated as payload-origin: the corpus publishes
      # real https://api.github.com Link targets, so an application-origin request built
      # from one would be refused as scheme_not_allowed in fixture mode and offline
      # pagination could not work through this contract at all.
      #
      # @param origin [Symbol] :application for a location this adapter constructed,
      #   :payload for one GitHub supplied (a Link target)
      # @return [Github::Request]
      def request_for(url, etag: nil, origin: :application)
        Request.new(url: url, request_class: REQUEST_CLASS, etag: etag, origin: origin,
                    context: { source_type: source_type })
      end

      # The adapter's own endpoint, so application-origin by definition — which is what
      # lets the offline source address the corpus with a scheme no payload could supply.
      #
      # @return [Github::Request]
      def first_page_request(etag: nil)
        request_for(first_page_url, etag: etag, origin: :application)
      end

      # A page GitHub pointed at through a Link header. Named separately from
      # #request_for so the origin is not something a caller has to remember.
      #
      # @return [Github::Request]
      def linked_page_request(url)
        request_for(url, origin: :payload)
      end

      # Decodes one fetched page into raw GitHub event envelopes. This is the seam PR 5's
      # processor registry consumes: no filtering, typing, or normalisation happens here,
      # because §7 retains the raw payload and PR 5's quarantine taxonomy has to be able
      # to tell a malformed response from a malformed event.
      #
      # @param fetch_result [Github::FetchResult]
      # @return [Array<Object>] the decoded array, elements untouched — including nulls,
      #   which a valid JSON array can legitimately contain and which PR 5 quarantines
      # @raise [Github::Errors::MalformedResponse] when the body is not a JSON array
      def events(fetch_result)
        decoded = JSON.parse(fetch_result.body.to_s)
        unless decoded.is_a?(Array)
          raise Errors::MalformedResponse,
                "#{source_type} expected a JSON array of events, got #{decoded.class}"
        end

        decoded
      rescue JSON::ParserError => e
        raise Errors::MalformedResponse, "#{source_type} response body is not valid JSON: #{e.message}"
      end
    end
  end
end
