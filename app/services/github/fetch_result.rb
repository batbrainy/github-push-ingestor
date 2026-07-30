module Github
  # What Github::RequestExecutor hands back, for every outcome (IMPLEMENTATION_PLAN.md §5).
  #
  # #call has one return type on purpose. A budget denial, a URL-policy rejection, a
  # gate deferral, exhausted retries, and a transport failure are all ordinary
  # outcomes of trying to reach a rate-limited third party, and a caller that has to
  # rescue four exception classes to poll a page will eventually miss one.
  #
  # The body stays a String. Decoding belongs to the event source and, in PR 5, to the
  # processor: §7 retains the raw payload, and the malformed-event taxonomy has to be
  # able to tell "this body is not JSON" from "this event is malformed".
  #
  # Subclassing Data.define rather than passing it a block, so the classification
  # constants below are scoped to this class instead of to Github.
  class FetchResult < Data.define(
    :request, :status, :headers, :body, :error, :duration_ms, :attempt, :classification
  )
    # Outcomes decided before or instead of an HTTP status. They carry no status
    # because none was obtained. Which specific failure it was lives on #error, so the
    # vocabulary stays small enough for a caller to branch on exhaustively.
    #
    #   :transport_error   network-level and retryable (§10's "network timeout")
    #   :permanent_error   no status and not worth retrying: TLS, a URL-policy
    #                      violation, an exhausted redirect budget, a fixture miss
    #   :budget_denied     the ledger refused; nothing was spent
    #   :gate_unavailable  the global gate was busy; nothing was spent
    NON_HTTP_CLASSIFICATIONS = %i[
      transport_error permanent_error budget_denied gate_unavailable
    ].freeze

    CLASSIFICATIONS = (ResponseClassifier::CLASSIFICATIONS + NON_HTTP_CLASSIFICATIONS).freeze

    # Neither of these means the request failed — they mean it never happened. A caller
    # reschedules rather than recording a failure (§9, §10).
    DEFERRED_CLASSIFICATIONS = %i[ budget_denied gate_unavailable ].freeze

    class << self
      def from_response(request:, status:, headers:, body:, duration_ms:, attempt: 0)
        new(
          request: request,
          status: status,
          headers: normalize(headers),
          body: body,
          error: nil,
          duration_ms: duration_ms,
          attempt: attempt,
          classification: ResponseClassifier.classify(status: status, headers: headers)
        )
      end

      def from_error(request:, error:, classification:, duration_ms: 0.0, attempt: 0)
        new(
          request: request, status: nil, headers: {}.freeze, body: nil, error: error,
          duration_ms: duration_ms, attempt: attempt, classification: classification
        )
      end

      def normalize(headers)
        (headers || {}).to_h { |name, value| [ name.to_s.downcase, value.to_s ] }.freeze
      end
    end

    def ok? = classification == :ok
    def not_modified? = classification == :not_modified
    def successful? = ResponseClassifier.successful?(classification)
    def deferred? = DEFERRED_CLASSIFICATIONS.include?(classification)

    def header(name)
      headers[name.to_s.downcase]
    end

    def etag = header("etag")
    def location = header("location")

    # The raw Link header. Parsing it into next/last is Github::LinkHeader's job; this
    # only guarantees the value survives the trip.
    def link_header = header("link")

    def rate_limit(observed_at: Time.current)
      RateLimitSnapshot.from_headers(headers, observed_at: observed_at)
    end

    def to_log
      request.to_log.merge(
        http_status: status, classification: classification, attempt: attempt,
        duration_ms: duration_ms, error_class: error&.class&.name, error_message: error&.message
      ).compact
    end
  end
end
