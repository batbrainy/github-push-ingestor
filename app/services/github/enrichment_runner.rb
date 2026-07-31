module Github
  # One enrichment cycle (IMPLEMENTATION_PLAN.md §13's PR 7), in the order §10 and §12
  # require:
  #
  #   1. age candidates past their eligibility window into skipped_budget — for both
  #      classes, on every invocation, before anything else
  #   2. ask §10's fairness policy which class works next, from which pool, and whether it
  #      may borrow
  #   3. lease that entity row, so a second worker cannot take it
  #   4. fetch it through Github.executor — the one and only network call
  #   5. record the global rate-limit consequence, then the entity outcome
  #
  # Step 1 comes first deliberately. §12's sequence is "exhaustion → deferred →
  # skipped_budget → reactivation", which requires skipping to keep happening *while* the
  # budget is exhausted — precisely when boundedness matters. Behind the fairness decision
  # it would stop exactly then, and the backlog would grow without limit.
  #
  # **At most one entity per call.** §5 names EnrichActorJob and EnrichRepositoryJob, and one
  # entity is what each of them performs; batching is the caller's loop, which
  # Github::Enrichment::OneShot is for the operator and the 60-second reconciler tick is for
  # the worker.
  #
  # **No source lock, ever.** §8 step 1: "Enrichment jobs skip this step — they take only
  # the request gate." This class is never handed an EventSource and never reaches for
  # Github::SourceLock, which is the structural half of Appendix D item 1;
  # Github::LockOrder is the enforced half.
  #
  # **No transaction spans the fetch.** This class opens none, every collaborator's write
  # is a single statement, and the three that write are constructed with no executor and
  # no transport — Github::Ingestion::PageWriter's technique. Github::BudgetLedger's
  # assert_committable! is the enforced backstop: every attempt goes through the executor,
  # and it raises if a transaction is open.
  class EnrichmentRunner
    MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

    # One return type for every outcome, so a caller branches once instead of rescuing
    # four classes and eventually missing one — IngestionRunner::Result's rule.
    #
    #   enriched   the document was stored
    #   failed     the entity reached permanent_failure or retryable_failure
    #   deferred   the request never happened, or produced nothing chargeable to this
    #              entity: a ledger denial, a busy gate, a rate limit
    #   idle       nothing was eligible — the ordinary steady state once a corpus is
    #              fully enriched, and a different fact from "we asked and were refused"
    #   lease_lost the outcome arrived after another worker had claimed the row
    class Result < Data.define(:status, :entity_type, :github_id, :pool, :borrow,
                               :classification, :enrichment_status, :last_error,
                               :error_code, :deferral_reason, :next_retry_at, :aged_out,
                               :duration_ms, :enrichment_attempt)
      STATUSES = %w[ enriched failed deferred idle lease_lost ].freeze

      # §11 names the INFO events "enrichment completed/failed/skipped/reactivated", so the
      # log vocabulary is the plan's rather than this object's. "skipped" is
      # Github::Enrichment::AgeOut's line and "reactivated" is the ingest path's; the five
      # here are the outcomes of one cycle.
      EVENTS = {
        "enriched" => "enrichment.completed", "failed" => "enrichment.failed",
        "deferred" => "enrichment.deferred", "idle" => "enrichment.idle",
        "lease_lost" => "enrichment.lease_lost"
      }.freeze

      def initialize(status:, entity_type: nil, github_id: nil, pool: nil, borrow: false,
                     classification: nil, enrichment_status: nil, last_error: nil,
                     error_code: nil, deferral_reason: nil, next_retry_at: nil,
                     aged_out: 0, duration_ms: nil, enrichment_attempt: nil)
        raise ArgumentError, "unknown status #{status.inspect}" unless STATUSES.include?(status)

        super
      end

      def enriched? = status == "enriched"
      def failed? = status == "failed"
      def deferred? = status == "deferred"
      def idle? = status == "idle"
      def lease_lost? = status == "lease_lost"

      # Whether a live GitHub request was made. A deferral spends nothing.
      def attempted? = enriched? || failed? || lease_lost?

      def to_log
        { enrichment_outcome: status, entity_type: entity_type, github_id: github_id,
          pool: pool, borrow: (true if borrow), classification: classification,
          entity_status: enrichment_status, enrichment_attempt: enrichment_attempt,
          error_code: error_code,
          error_message: last_error, deferral_reason: deferral_reason,
          next_retry_at: next_retry_at&.utc&.iso8601,
          aged_out: (aged_out if aged_out.positive?), duration_ms: duration_ms }.compact
      end
    end

    def initialize(executor: Github.executor,
                   configuration: Github.configuration,
                   clock: -> { Time.current },
                   monotonic: MONOTONIC,
                   rate_limit_policy: RateLimitPolicy.new,
                   selector: nil, fairness: nil, claim: nil, age_out: nil, entity_state: nil)
      @executor = executor
      @configuration = configuration
      @clock = clock
      @monotonic = monotonic
      @rate_limit_policy = rate_limit_policy
      @selector = selector || Enrichment::CandidateSelector.new(configuration: configuration)
      @fairness = fairness || Enrichment::Fairness.new(configuration: configuration, selector: @selector)
      @claim = claim || Enrichment::Claim.new(configuration: configuration, selector: @selector)
      @age_out = age_out || Enrichment::AgeOut.new(configuration: configuration, selector: @selector)
      @entity_state = entity_state || Enrichment::EntityState.new
    end

    # @param entity_class [Class, Symbol, nil] restrict this cycle to one class. It
    #   narrows selection and bypasses nothing: the allowance, the share, the reserve, the
    #   gate and every global block still bind.
    # @return [Result]
    def call(entity_class: nil)
      now = @clock.call
      started = @monotonic.call
      aged = @age_out.call(now: now).values.sum

      choice = @fairness.choose(entity_class: entity_class, now: now)
      return idle(choice, aged: aged, started: started) unless choice.chosen?

      lease = @claim.acquire(choice.entity_type, pool: choice.pool, now: now)
      # A lost race, or a row that moved between the query and the claim. Nothing is
      # wrong, and there is nothing to report about an entity we never held.
      return idle(Enrichment::Fairness::Choice.none(reason: "no_candidate"), aged: aged, started: started) if lease.nil?

      enrich(choice, lease, aged: aged, started: started)
    end

    private

    def enrich(choice, lease, aged:, started:)
      fetched = @executor.call(request_for(choice, lease))
      # Before the entity write: a rate limit is a fact about the IP, the global block has
      # to be recorded first, and the secondary-limit branch of the write matrix reads the
      # instant this returns. Github::Ingestion::PageLoop sequences a poll the same way.
      decision = @rate_limit_policy.apply!(fetched, now: @clock.call)
      document = fetched.ok? ? choice.entity_type.document.parse(fetched.body, github_id: lease.github_id) : nil

      written = @entity_state.record!(lease: lease, fetched: fetched, document: document,
                                      decision: decision, now: @clock.call)
      @claim.release!(lease) if written.lease_held

      complete(choice, lease, fetched, written, aged: aged, started: started)
    rescue Errors::FixtureMiss
      # §6 requires a corpus gap to be raised rather than laundered into a failed fetch.
      # The lease goes back untouched: an authoring bug is not an entity outcome and must
      # not cost the entity an attempt.
      @claim.release!(lease)
      raise
    rescue StandardError => error
      # PageWriter's reasoning: an unexpected error "is a defect to fix, not a payload to
      # classify". Fabricating an entity status from one would make the defect durable.
      @claim.release!(lease)
      # enrichment.cycle_failed, not enrichment.failed: Result::EVENTS owns that name for
      # the *ordinary* outcome §11 lists — INFO, with an entity status and a scheduled
      # retry. This is an escaped exception with a released lease, an error pair and no
      # entity outcome at all, and one event name carrying two field sets means an alert
      # filtered on it matches two structurally different records.
      # PollEventSourceJob's ingestion.cycle_failed is the same fact one level up, and
      # shares its name deliberately.
      Rails.logger.error(event: "enrichment.cycle_failed", **lease.to_log,
                         error_class: error.class.name, error_message: error.message)
      raise
    end

    # origin: :payload, because §10's SSRF boundary treats an actor or repository URL that
    # arrived inside an event payload as attacker-influenced: it clears the full *live*
    # policy first whatever the mode, and only then is projected onto the fixture scheme.
    #
    # A blank or NULL api_url needs no special case. It becomes "", which
    # Github::RequestExecutor's *pre-gate* validation refuses — outside the gate hold and
    # therefore before any reservation — so it arrives back as :permanent_error and costs
    # no budget. That is §10's "violations mark the entity permanent_failure", satisfied
    # by the chain that already exists.
    #
    # The context keys are §11's common fields, and they reach the DEBUG github.request
    # line through Request#to_log with no change to the executor or the formatter. The
    # attempt key is spelled enrichment_attempt on purpose: FetchResult#to_log merges its
    # own `attempt` — the HTTP one — after the request's, and would silently overwrite it.
    def request_for(choice, lease)
      Request.new(
        url: lease.api_url,
        request_class: choice.entity_type.request_class,
        origin: :payload,
        borrow: choice.borrow,
        context: lease.to_log
      )
    end

    def complete(choice, lease, fetched, written, aged:, started:)
      result = Result.new(
        status: written.outcome, entity_type: choice.entity_type.key,
        github_id: lease.github_id, pool: choice.pool, borrow: choice.borrow,
        classification: fetched.classification, enrichment_status: written.enrichment_status,
        # §11's "attempt number", spelled enrichment_attempt for the reason #request_for's
        # comment gives: `attempt` on a github.* line is the HTTP one. lease.to_log already
        # carries this onto the DEBUG request line; without it here it never reaches the
        # INFO outcome line, which is the line §11 actually asks reviewers to read.
        enrichment_attempt: lease.enrichment_attempts + 1,
        last_error: written.last_error, error_code: written.error_code,
        deferral_reason: (fetched.classification.to_s if written.deferred?),
        next_retry_at: written.next_retry_at, aged_out: aged,
        duration_ms: elapsed_ms(started)
      )

      log(result)
      result
    end

    def idle(choice, aged:, started:)
      # A deferral the ledger would have refused is reported as such; genuinely having
      # nothing to do is idle. IngestionRunner draws the same line between "not due" and
      # "deferred", and for the same reason: they are different facts and an operator acts
      # on them differently.
      deferred = choice.reason != "no_candidate"

      result = Result.new(status: deferred ? "deferred" : "idle",
                          deferral_reason: choice.reason, aged_out: aged,
                          duration_ms: elapsed_ms(started))
      log(result)
      result
    end

    # §11 lists "enrichment completed/failed/skipped/reactivated, retry scheduled" among
    # the INFO events. A deferral or an idle cycle is DEBUG: under PR 8's recurring task
    # an exhausted window would otherwise emit a line a minute for the rest of the hour,
    # which is the volume argument Github::BudgetLedger#log_class_exhausted already makes.
    def log(result)
      payload = result.to_log.merge(event: Result::EVENTS.fetch(result.status))

      result.attempted? ? Rails.logger.info(payload) : Rails.logger.debug(payload)
    end

    def elapsed_ms(started)
      ((@monotonic.call - started) * 1000).round(1)
    end
  end
end
