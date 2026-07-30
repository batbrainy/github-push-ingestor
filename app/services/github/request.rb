module Github
  # One outbound GitHub request, described before anything is spent on it.
  #
  # The request *class* is the field that matters most: it is what the budget ledger
  # debits (IMPLEMENTATION_PLAN.md §7) and what PR 5 and PR 7 use to tell a source
  # failure from an entity failure (§10). It is a required constructor argument,
  # validated at construction, and no component ever infers it.
  #
  # Subclassing Data.define rather than passing it a block: a constant assigned inside
  # that block would be scoped to the enclosing module, so CLASSES would silently
  # become Github::CLASSES.
  class Request < Data.define(:url, :request_class, :origin, :http_method, :custom_headers, :etag, :context)
    # §7: every outbound attempt debits its class counter. :poll comes from an event
    # source, :actor and :repository from enrichment (PR 7).
    CLASSES = %i[ poll actor repository ].freeze
    ENRICHMENT_CLASSES = %i[ actor repository ].freeze

    # Where the URL came from, which decides how strictly Github::UrlPolicy validates it.
    #
    #   :application  a location this application constructed — an event source's own
    #                 endpoint. Validated against the current mode directly.
    #   :payload      a location GitHub supplied inside an event payload, a Link header,
    #                 or a Location header, and therefore one an attacker could
    #                 influence. Always validated against the full *live* policy first,
    #                 whatever the mode.
    ORIGINS = %i[ application payload ].freeze

    # §2A pins all three. GitHub recommends the media type and version headers, and
    # rejects requests without a valid User-Agent. The version is 2022-11-28 because
    # that is the version every live probe behind this plan was run under.
    PROTOCOL_HEADERS = {
      "Accept" => "application/vnd.github+json",
      "X-GitHub-Api-Version" => "2022-11-28",
      "User-Agent" => "github-push-ingestor"
    }.freeze

    def initialize(url:, request_class:, origin: :application, http_method: :get,
                   custom_headers: {}, etag: nil, context: {})
      unless CLASSES.include?(request_class)
        raise ArgumentError, "request_class must be one of #{CLASSES.inspect}, got #{request_class.inspect}"
      end
      raise ArgumentError, "origin must be one of #{ORIGINS.inspect}, got #{origin.inspect}" unless ORIGINS.include?(origin)

      super(
        url: url.to_s.freeze,
        request_class: request_class,
        origin: origin,
        http_method: http_method,
        custom_headers: custom_headers.freeze,
        etag: etag&.to_s&.freeze,
        context: context.freeze
      )
    end

    # PROTOCOL_HEADERS merges last, so a caller cannot drop or override them by
    # passing its own User-Agent. The live transport applies them again as connection
    # defaults, so even a hand-built request that skipped this method carries them.
    def headers
      custom_headers.merge(conditional_headers).merge(PROTOCOL_HEADERS)
    end

    def conditional_headers
      etag.present? ? { "If-None-Match" => etag } : {}
    end

    def enrichment?
      ENRICHMENT_CLASSES.include?(request_class)
    end

    def payload_supplied?
      origin == :payload
    end

    # A redirect hop is a separate outbound request to GitHub, so it keeps the
    # originating request's class and is reserved again (§7); retries reuse the original
    # request unchanged. The hop becomes payload-origin however the original was built,
    # because a Location header is server-supplied and must clear the full live policy
    # before it is followed.
    def redirected_to(location)
      with(url: location.to_s.freeze, etag: nil, origin: :payload)
    end

    def to_log
      { request_class: request_class, http_method: http_method, url: url, origin: origin }.merge(context)
    end
  end
end
