module Github
  module Ingestion
    # The `Link`-driven page walk for one polling operation (IMPLEMENTATION_PLAN.md §9).
    #
    # §9's four stop conditions:
    #
    #   * the configured page cap is reached
    #   * the budget ledger denies the next reservation
    #   * no next `Link` exists
    #   * an empty page is returned
    #
    # And, emphatically, **no stop-on-known-event**. §9 is explicit about why: documented
    # event latency is 30s–6h and the API does not guarantee that one previously seen
    # event implies every older position is already stored, so a delayed event can surface
    # later beside an already-seen one. Every fetched page is processed in full and
    # github_event_id uniqueness absorbs the duplicates. The corpus proves the absence
    # rather than this comment merely asserting it: page-2.json repeats page one's first
    # event, so a known-event stop would end the walk there.
    #
    # Two stops §9 does not enumerate are needed anyway, and are named rather than folded
    # into the four, so a reader can tell a healthy walk from a truncated one:
    #
    #   * :link_loop — a next target this walk already fetched. Without it, a
    #     self-referential Link header spends the entire hourly poll allowance in one run.
    #   * :page_error — a non-success on page two or later, after retries.
    #
    # This class holds no transaction. PageWriter opens one per envelope and commits it
    # before the next fetch, which is what lets a page loop exist at all: BudgetLedger
    # refuses a reservation inside an open application transaction, because an outer
    # rollback would refund a request GitHub has already counted.
    class PageLoop
      STOP_REASONS = %i[ page_cap budget_denied no_next_link empty_page link_loop page_error ].freeze

      # Classifications where the request reached GitHub and GitHub declined to serve it.
      # Recorded as deferred rather than failed: §10 treats a rate limit as something to
      # retry later, and nothing is wrong with the request.
      DEFERRING_CLASSIFICATIONS = %i[ rate_limited secondary_limited ].freeze

      # §10: "/events returns permanent 4xx → source failed/disabled". Distinguished from
      # a server error, which is retried and leaves the source healthy.
      SOURCE_FAILING_CLASSIFICATIONS = %i[ client_error not_found ].freeze

      # Everything the run row, the source row, and the operator's line need, assembled
      # once. Nested inside its producer, like IngestionRunner::Result and OneShot::Result.
      class Outcome < Data.define(:status, :tally, :classification, :last_error, :deferral_reason,
                                  :stop_reason, :etag, :snapshot, :source_failing, :decision)
        def initialize(status:, tally: Tally.empty, classification: nil, last_error: nil,
                       deferral_reason: nil, stop_reason: nil, etag: nil, snapshot: nil,
                       source_failing: false, decision: RateLimitPolicy::Decision.none)
          super
        end

        # The runner's rescue path: an error this class never saw, so it carries no
        # classification and no snapshot, and PollState treats it as an unattempted run.
        def self.failure(error)
          new(status: "failed", last_error: "#{error.class.name}: #{error.message}")
        end

        def completed? = status == "completed"
        def not_modified? = status == "not_modified"
        def deferred? = status == "deferred"
        def failed? = status == "failed"
        def successful? = IngestionRun::SUCCESSFUL_STATUSES.include?(status)

        # Whether a poll attempt actually happened — the predicate that decides which
        # scheduling columns may move. A budget denial and a held gate never reached
        # GitHub, so they must not advance a cadence or burn a failure count.
        def attempted?
          classification.present? && !FetchResult::DEFERRED_CLASSIFICATIONS.include?(classification)
        end

        def to_log
          { run_status: status, classification: classification, deferral_reason: deferral_reason,
            stop_reason: stop_reason, error_message: last_error }.compact.merge(tally.to_log)
        end
      end

      def initialize(executor: Github.executor, writer: PageWriter.new,
                     configuration: Github.configuration,
                     rate_limit_policy: RateLimitPolicy.new, clock: -> { Time.current })
        @executor = executor
        @writer = writer
        @configuration = configuration
        @policy = rate_limit_policy
        @clock = clock
      end

      attr_reader :executor, :writer, :configuration, :policy

      def now = @clock.call

      # @param source [Github::EventSources::Base]
      # @param etag [String, nil] the stored page-one ETag, or nil when there is none and
      #   when --force asked for an unconditional request. Only page one ever carries one:
      #   §9 scopes the persisted ETag to "the canonical first-page request, including its
      #   stable query parameters", and Base#linked_page_request takes no etag argument at
      #   all, so a later page structurally cannot reuse it.
      # @return [Outcome]
      def run(source, run_id:, etag: nil)
        Walk.new(page_loop: self, source: source, run_id: run_id, etag: etag).call
      end

      # One walk's mutable state. It lives here rather than in PageLoop's instance
      # variables so a single PageLoop can serve many runs without one leaking into the
      # next — the running tally, the pages already visited, and the strongest block
      # decision seen are all per-walk facts.
      class Walk
        def initialize(page_loop:, source:, run_id:, etag:)
          @loop = page_loop
          @source = source
          @run_id = run_id
          @etag = etag
          @tally = Tally.empty
          @visited = Set.new
          @decision = RateLimitPolicy::Decision.none
          @page_one = nil
          @latest = nil
          @page_error = nil
          @page_empty = false
        end

        def call
          request = @source.first_page_request(etag: @etag, context: { run_id: @run_id })
          page = 0

          loop do
            page += 1
            @visited << canonical(request.url)
            fetched = fetch(request, page: page)

            step = interpret(fetched, page: page)
            return step if step.is_a?(Outcome)
            return completed(step, page: page) if step.is_a?(Symbol)

            request = step
          end
        end

        private

        def fetch(request, page:)
          fetched = @loop.executor.call(request)
          @page_one ||= fetched
          @latest = fetched

          # Logged before anything decodes a body: a 304 and every deferral carry none,
          # and this line's position is what proves that ordering held.
          Rails.logger.debug(event: "ingestion.page_fetched", run_id: @run_id, page: page,
                             http_status: fetched.status, classification: fetched.classification,
                             attempt: fetched.attempt, duration_ms: fetched.duration_ms,
                             etag_sent: request.etag.present?,
                             link_next_present: !next_url(fetched).nil?)

          # A rate limit is a fact about the IP, not about which page asked for it, so the
          # policy sees every response — including one that arrived on page three.
          decision = @loop.policy.apply!(fetched, now: @loop.now)
          @decision = decision if decision.blocking?

          fetched
        end

        # @return [Outcome] the walk ends and this is the whole answer (page one only)
        # @return [Symbol] a stop reason; the walk ends and the run is completed
        # @return [Github::Request] the next page to fetch
        def interpret(fetched, page:)
          return page_one(fetched) if page == 1 && !fetched.ok?
          # Page two onwards, anything non-ok ends the walk and keeps what is already
          # persisted. Not `failed` — pages one to N-1 are durable, so "the attempt
          # happened and did not produce usable events" is simply untrue — and not
          # `deferred`, which means nothing was fetched and would drop a run holding real
          # events out of IngestionRun::SUCCESSFUL_STATUSES.
          return record_page_error(fetched, page: page) unless fetched.ok?

          process(fetched, page: page)
        end

        # PR 5's branch order, unchanged and still load-bearing: Base#events calls
        # JSON.parse on the body, and a 304 has none, so decoding before this branch would
        # turn a perfectly healthy 304 into a MalformedResponse and a failed run.
        def page_one(fetched)
          return not_modified(fetched) if fetched.not_modified?
          return deferral(fetched) if deferring?(fetched)

          outcome(status: "failed", classification: fetched.classification,
                  last_error: describe(fetched),
                  source_failing: SOURCE_FAILING_CLASSIFICATIONS.include?(fetched.classification))
        end

        def process(fetched, page:)
          envelopes = @source.events(fetched)
          @page_empty = envelopes.empty?
          @tally = @loop.writer.write(envelopes, run_id: @run_id,
                                      tally: @tally.record_page(events_received: envelopes.size))

          Rails.logger.debug(event: "ingestion.page_processed", run_id: @run_id, page: page,
                             events_received: envelopes.size, **@tally.to_log)

          stop_reason(fetched, page: page) || next_request(fetched, page: page)
        rescue Errors::MalformedResponse => error
          # §7's taxonomy row 5: an unusable response body is an ingestion failure, not an
          # individual quarantined event — nothing about it identifies an event. On a
          # later page it is one more reason to stop, not a reason to discard the pages
          # already committed.
          @page_error = "page #{page}: #{error.class.name}: #{error.message}"
          return :page_error if page > 1

          outcome(status: "failed", classification: fetched.classification, last_error: @page_error)
        end

        # Order matters, and it is data-driven stops before the configured one: several can
        # be true at once — the corpus's final page is both empty and Link-less — and
        # reporting :page_cap only when GitHub offered more makes it an actionable signal
        # that MAX_PAGES_PER_POLL is truncating capture, rather than a label on every run.
        def stop_reason(fetched, page:)
          return :empty_page if @page_empty

          target = next_url(fetched)
          return :no_next_link if target.nil?
          return :link_loop if @visited.include?(canonical(target))

          :page_cap if page >= @loop.configuration.max_pages_per_poll
        end

        def next_request(fetched, page:)
          # Payload origin, so UrlPolicy re-validates a server-supplied target under the
          # full live policy before it is followed — and, in fixture mode, projects it onto
          # the fixture scheme afterwards. Building it with request_for instead would
          # default to application origin and break every offline page after the first.
          @source.linked_page_request(next_url(fetched), context: { run_id: @run_id, page: page + 1 })
        end

        def completed(reason, page:)
          Rails.logger.debug(event: "ingestion.pagination_stopped", run_id: @run_id, reason: reason,
                             pages_fetched: page, max_pages: @loop.configuration.max_pages_per_poll)

          outcome(status: "completed", tally: @tally, classification: @page_one.classification,
                  stop_reason: reason, last_error: @page_error, etag: page_one_etag)
        end

        def record_page_error(fetched, page:)
          @page_error = "page #{page}: #{describe(fetched)}"

          fetched.deferred? ? :budget_denied : :page_error
        end

        def not_modified(fetched)
          Rails.logger.debug(event: "ingestion.not_modified", run_id: @run_id,
                             etag_sent: @etag, etag_returned: fetched.etag,
                             rate_limit_used: fetched.header("x-ratelimit-used"),
                             rate_limit_remaining: fetched.header("x-ratelimit-remaining"))

          outcome(status: "not_modified", classification: fetched.classification, etag: fetched.etag)
        end

        def deferral(fetched)
          reason = deferral_reason(fetched)

          Rails.logger.info(event: "ingestion.deferred", run_id: @run_id, reason: reason,
                            classification: fetched.classification, http_status: fetched.status)

          outcome(status: "deferred", classification: fetched.classification, deferral_reason: reason)
        end

        # The snapshot and the block decision ride on every outcome, because the poll-state
        # writer needs them and would otherwise have to reach back into FetchResults this
        # class has already interpreted.
        def outcome(**attributes)
          Outcome.new(snapshot: @latest&.rate_limit(observed_at: @loop.now),
                      decision: @decision, **attributes)
        end

        def deferring?(fetched)
          fetched.deferred? || DEFERRING_CLASSIFICATIONS.include?(fetched.classification)
        end

        # Errors::BudgetExhausted carries which of §10's four denial conditions refused the
        # reservation, and that is the one actionable fact about a deferral.
        def deferral_reason(fetched)
          error = fetched.error

          error.is_a?(Errors::BudgetExhausted) ? error.reason.to_s : fetched.classification.to_s
        end

        # §10 keeps every HTTP status a response rather than an exception, so the reason a
        # page failed is assembled from the classification and, when there was no status at
        # all, from the transport error.
        def describe(fetched)
          return "#{fetched.error.class.name}: #{fetched.error.message}" if fetched.error

          "GitHub returned #{fetched.status} (#{fetched.classification})"
        end

        # A 304 may carry an ETag and by definition it is the current validator, so it is
        # stored. A non-success carries an ETag for a body this application never asked
        # for, so it is ignored and the stored one is left alone rather than cleared —
        # clearing would make every later poll unconditional for no reason.
        def page_one_etag
          @page_one&.successful? ? @page_one.etag : nil
        end

        def next_url(fetched) = LinkHeader.next_url(fetched.link_header)

        # Path plus query sorted by name, so ?a=1&b=2 and ?b=2&a=1 are recognised as the
        # same page. Anything unparseable falls back to the raw string, which still catches
        # the realistic loop: a header pointing at the URL just fetched.
        def canonical(url)
          uri = URI.parse(url.to_s)
          query = URI.decode_www_form(uri.query.to_s).sort

          query.empty? ? uri.path.to_s : "#{uri.path}?#{URI.encode_www_form(query)}"
        rescue URI::Error, ArgumentError
          url.to_s
        end
      end
    end
  end
end
