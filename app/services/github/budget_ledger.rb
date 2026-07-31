module Github
  # The class-aware request budget (IMPLEMENTATION_PLAN.md §7, §10). Every outbound
  # live request from any process — poller, worker, one-shot — reserves capacity here
  # transactionally *before* execution, because the unauthenticated limit is keyed to
  # the outbound IP rather than to any one event source.
  #
  # The division of labour is: **the ledger enforces and records, the policy decides.**
  # This class refuses a reservation it has no capacity for, and it is the only writer of
  # github_api_budget — but *which* condition warrants a global block, and until when, is
  # Github::RateLimitPolicy's call, and it is the only caller of #block_globally!.
  # Scheduling reads nothing from here beyond two columns: class blocking is derived on
  # GithubApiBudget itself.
  #
  # §10's fairness split between actors and repositories is enforced here, under the same
  # row lock as the debit, because ADR 0004 makes this the only writer of the row. The one
  # fact it cannot establish is whether the *other* class has a currently eligible
  # candidate — that lives in github_actors and github_repositories, and reaching for two
  # more tables from inside the most contended row lock in the application would invert
  # the locking discipline. So the caller asserts it (`borrow:`) and this class enforces
  # the arithmetic.
  #
  # Three properties this class exists to hold:
  #
  #   * Reservation before execution. A 200, a 304, a retry after a 5xx, a one-shot
  #     poll, an actor request and a repository request all debit first.
  #   * Failures stay spent. There is no credit!, no refund!, no release!. A network
  #     failure with no response headers keeps its reservation, and the next successful
  #     response reconciles local state against GitHub's.
  #   * Monotonic reconciliation. Response headers are authoritative but may arrive out
  #     of order, so within one reset window remaining only ever moves down.
  class BudgetLedger
    SINGLETON_ID = GithubApiBudget::SINGLETON_ID

    # :share_exhausted rather than :class_share_exhausted. In this file "class" already
    # means poll-versus-enrichment (class_used, class_allowance,
    # :class_allowance_exhausted); the share sits *inside* the enrichment class, between
    # actor and repository, so reusing the word would overload it with the wrong scope.
    DENIAL_REASONS = %i[
      globally_blocked window_uninitialized reserve_reached class_allowance_exhausted
      share_exhausted
    ].freeze

    # One statement per class rather than an interpolated column list: this is the most
    # safety-critical SQL in the application, and a reviewer should be able to read
    # exactly what a debit of each class does without reassembling it from fragments.
    #
    # Two details in every one of them:
    #
    #   * remaining uses CASE WHEN ... IS NULL, not GREATEST(remaining - 1, 0).
    #     PostgreSQL's GREATEST *ignores* NULL, so GREATEST(NULL - 1, 0) evaluates to
    #     0 — which would turn an un-bootstrapped remaining into a permanent reserve
    #     breach that denies every request, including the bootstrap poll that is the
    #     only thing able to refresh it.
    #   * lock_version is bumped by hand because this is not an Active Record save.
    #     Any stale in-memory GithubApiBudget that later calls #save! must still raise
    #     StaleObjectError rather than clobbering the counters.
    #
    # The WHERE guard repeats the check denial_reason already made under the row lock.
    # It is defence in depth: if it ever rejects, the two disagree and that is a bug,
    # not a denial.
    #
    # The two enrichment statements carry a third bind, the class's share cap, which
    # reserve! computes once and hands to both denial_reason and this statement — so the
    # guard stays a literal repeat rather than a second, separately derived predicate
    # that could drift. Under a borrow that cap is enrichment_allowance, so the guard
    # degenerates into the class check, which is what borrowing means spelled in SQL.
    DEBIT_SQL = {
      poll: <<~SQL.squish,
        UPDATE github_api_budget
           SET poll_used = poll_used + 1,
               remaining = CASE WHEN remaining IS NULL THEN NULL ELSE GREATEST(remaining - 1, 0) END,
               lock_version = lock_version + 1,
               updated_at = ?
         WHERE id = ? AND poll_used < poll_allowance
      SQL
      actor: <<~SQL.squish,
        UPDATE github_api_budget
           SET enrichment_used = enrichment_used + 1,
               actor_share_used = actor_share_used + 1,
               remaining = CASE WHEN remaining IS NULL THEN NULL ELSE GREATEST(remaining - 1, 0) END,
               lock_version = lock_version + 1,
               updated_at = ?
         WHERE id = ? AND enrichment_used < enrichment_allowance AND actor_share_used < ?
      SQL
      repository: <<~SQL.squish
        UPDATE github_api_budget
           SET enrichment_used = enrichment_used + 1,
               repository_share_used = repository_share_used + 1,
               remaining = CASE WHEN remaining IS NULL THEN NULL ELSE GREATEST(remaining - 1, 0) END,
               lock_version = lock_version + 1,
               updated_at = ?
         WHERE id = ? AND enrichment_used < enrichment_allowance AND repository_share_used < ?
      SQL
    }.freeze

    # remaining and reset_at are nulled, not preserved. A dead window's remaining of 3
    # against a reserve of 8 would deny every request forever — including the bootstrap
    # poll that is the only thing that could refresh it. "limit" is deliberately kept:
    # it is the last authoritative observation and feeds the next derivation.
    #
    # The CASE on global_blocked_until clears a primary-exhaustion block, which was set
    # to the reset that has now passed, while preserving a secondary-limit block that
    # extends beyond it — the two conditions §10 distinguishes.
    #
    # The four counters are parameters rather than literal zeros so a rollover
    # discovered *during* reconciliation can carry the request that produced the
    # response into the window GitHub says it belongs to. See #reconcile!.
    ROLL_WINDOW_SQL = <<~SQL.squish
      UPDATE github_api_budget
         SET poll_used = ?, enrichment_used = ?,
             actor_share_used = ?, repository_share_used = ?,
             remaining = NULL, reset_at = NULL,
             window_status = 'uninitialized', window_initialized_at = NULL,
             global_blocked_until = CASE WHEN global_blocked_until <= ? THEN NULL ELSE global_blocked_until END,
             poll_allowance = ?, enrichment_allowance = ?, reserve = ?,
             lock_version = lock_version + 1, updated_at = ?
       WHERE id = ?
    SQL

    # Deliberately does not touch the counters. That is what makes §7's "the first real
    # poll, not an extra request" literally true: the bootstrap poll's debit survives
    # initialization and the window opens with poll_used already at 1.
    #
    # LEAST relies on PostgreSQL ignoring NULL — at bootstrap remaining is NULL, so this
    # takes the observed value, and on any later same-window call it is genuinely
    # monotonic. One statement, both meanings.
    INITIALIZE_WINDOW_SQL = <<~SQL.squish
      UPDATE github_api_budget
         SET "limit" = ?, remaining = LEAST(remaining, ?), reset_at = ?,
             observed_at = ?, window_initialized_at = ?, window_status = 'active',
             poll_allowance = ?, enrichment_allowance = ?, reserve = ?,
             lock_version = lock_version + 1, updated_at = ?
       WHERE id = ?
    SQL

    MONOTONIC_UPDATE_SQL = <<~SQL.squish
      UPDATE github_api_budget
         SET "limit" = COALESCE(?, "limit"), remaining = LEAST(remaining, ?),
             observed_at = ?, lock_version = lock_version + 1, updated_at = ?
       WHERE id = ?
    SQL

    # GREATEST here relies on the same PostgreSQL NULL behaviour DEBIT_SQL's comment warns
    # about, but as the feature rather than the hazard: with no block stored, GREATEST
    # ignores the NULL and takes the new instant; with one stored, it takes the later of
    # the two. **A block can only ever move later.** Without that, a 60-second secondary
    # limit landing after an hour-long primary exhaustion would shorten it, and the
    # application would resume polling into a quota that is provably at zero and spend the
    # rest of the window collecting 403s. The global gate orders *requests*, not the
    # post-response writes that follow them, so that ordering is reachable.
    #
    # COALESCE on window_status keeps the label's fate in the policy's hands without a
    # boolean bind: nil leaves it alone.
    #
    # lock_version is bumped by hand for the reason DEBIT_SQL gives — this is not an
    # Active Record save, and a stale in-memory row must still raise StaleObjectError
    # rather than clobber the counters.
    BLOCK_SQL = <<~SQL.squish
      UPDATE github_api_budget
         SET global_blocked_until = GREATEST(global_blocked_until, ?),
             window_status = COALESCE(?, window_status),
             lock_version = lock_version + 1, updated_at = ?
       WHERE id = ?
    SQL

    def initialize(configuration: Github.configuration, allocation: SourceAllocation.new(configuration: configuration))
      @configuration = configuration
      @allocation = allocation
    end

    attr_reader :configuration, :allocation

    # Debits one request attempt of the given class, transactionally, before the
    # request is performed.
    #
    # @param request_class [Symbol] :poll, :actor, or :repository
    # @param borrow [Boolean] §10's fairness borrowing: the caller's assertion that the
    #   other enrichment class has no *currently eligible* candidate, so this one may
    #   spend past its guarantee. See the class comment for why this is asserted rather
    #   than established here.
    # @return [GithubApiBudget] the row after the debit
    # @raise [Github::Errors::BudgetExhausted] carrying the denial reason
    def reserve!(request_class, now: Time.current, borrow: false)
      assert_known_class!(request_class)
      assert_borrowable!(request_class, borrow)
      assert_committable!
      bootstrap!(now: now)

      budget, reason = uncached_transaction do
        budget = GithubApiBudget.lock.find(SINGLETON_ID)
        budget = roll_window!(budget, now: now) if window_elapsed?(budget, now)

        # Computed once and handed to both the predicate and the statement. That is what
        # keeps DEBIT_SQL's guard a *repeat* of denial_reason's check rather than a
        # second derivation, and it is why a granted reservation can never then be
        # rejected by the SQL.
        cap = share_cap(budget, request_class, borrow: borrow)

        denial = denial_reason(budget, request_class, now, share_cap: cap)
        # The rollover above commits even when the reservation is refused, so the reason
        # is carried out of the transaction and raised after it: a denial must not undo
        # a window reset that has genuinely happened.
        next [ budget, denial ] if denial

        [ debit!(request_class, now: now, share_cap: cap, borrow: borrow), nil ]
      end

      raise Errors::BudgetExhausted.new(request_class, reason) if reason

      budget
    end

    # Reconciles local state against authoritative response headers, inside the gate
    # hold. Returns a symbol describing what it did, so the caller can log it.
    #
    # If this raises, the debit is already committed and the ledger is left
    # conservative — over-counted usage, a stale-high remaining that the next success
    # clamps. That is the same posture as failures-stay-spent, and it beats swallowing
    # the exception, which would hide accounting bugs behind a slowly drifting ledger.
    # @param request_class [Symbol, nil] the class of the request that produced this
    #   response. Supplied by Github::RequestExecutor; nil only for a caller that is
    #   reconciling without an in-flight request.
    def reconcile!(snapshot, request_class: nil, now: Time.current)
      assert_committable!
      return :no_headers if snapshot.nil?

      uncached_transaction do
        budget = GithubApiBudget.lock.find_by(id: SINGLETON_ID)
        # reconcile! never creates the row. Only a reservation does, and a response
        # arriving without one would mean a request was made without reserving.
        next :no_ledger if budget.nil?
        next :resource_mismatch if resource_mismatch?(budget, snapshot)

        # One decision, not two sequential ones. The clock predicate and the header
        # predicate describe the same event — the window moved on — and evaluating them
        # in sequence made a second rollover reachable, which then fell through
        # apply_observation's branches and raised.
        if window_elapsed?(budget, now) || window_superseded?(budget, snapshot)
          # The request that produced this response was reserved against the window that
          # has just ended, but GitHub counted it in the new one — that is precisely
          # what a superseding reset_at means. Zeroing the counters outright would let
          # this window issue one more request than GitHub will honour, so the debit is
          # carried forward rather than discarded.
          budget = roll_window!(budget, now: now, carry_forward: request_class)
        end

        # An error page, a proxy response, or a partial header set carries nothing to
        # apply. Not an error.
        next :partial_headers unless snapshot.quantitative?

        apply_observation(budget, snapshot, now: now)
      end
    end

    # Creates the singleton row if it is missing. Nobody seeds it: db/seeds.rb runs only
    # when db:prepare creates a database and db:test:prepare never seeds at all, so a
    # seeded row would exist in development and be absent in test — the worst possible
    # split. A migration is wrong for the same reason, since schema.rb carries no rows.
    #
    # Runs in its own statement *before* the reservation transaction opens: a
    # RecordNotUnique raised inside that transaction would poison it, which is exactly
    # the PostgreSQL hazard spec/support/constraint_helpers.rb already documents.
    #
    # Under READ COMMITTED — the default this application does not change — a losing
    # concurrent insert blocks on the winner's uncommitted tuple, then does nothing, and
    # the subsequent SELECT ... FOR UPDATE takes a fresh snapshot and sees the committed
    # row. Correct with no retry.
    def bootstrap!(now: Time.current)
      derived = configured_allowances

      GithubApiBudget.connection.exec_insert(
        ActiveRecord::Base.sanitize_sql_array([ <<~SQL.squish,
          INSERT INTO github_api_budget
            (id, poll_allowance, enrichment_allowance, reserve, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT (id) DO NOTHING
        SQL
          SINGLETON_ID, derived.poll_allowance, derived.enrichment_allowance, derived.reserve, now, now
        ]),
        "Github::BudgetLedger Bootstrap"
      )
    end

    # §10's three truly-global conditions — primary exhaustion, the reserve being reached,
    # and a secondary rate limit — recorded so every live request stops until the instant
    # passes. Enrichment has no source row to defer, and a secondary limit is IP-scoped
    # and can arise on an enrichment request, which is why this is global rather than
    # per-source (Appendix D item 2).
    #
    # It records; it does not decide. Github::RateLimitPolicy chooses the instant and the
    # label, having read the response that justified them.
    #
    # Called after the request has returned and the gate has been released, never while
    # holding it: the row lock taken here must stay the innermost lock in the system. A
    # process holding it and then reaching for the gate, while another holds the gate and
    # waits on this row, is a genuine cycle — PostgreSQL would abort one side, or the
    # gate's lock_timeout would fire and report a gate that was never actually contended.
    #
    # @param until_at [Time] when live requests may resume
    # @param reason [Symbol] :primary_rate_limit | :secondary_rate_limit | :reserve_reached
    # @param window_status [String, nil] "globally_blocked", or nil to leave the label
    #   untouched. See RateLimitPolicy for when each applies.
    # @return [Symbol] :blocked, or :no_ledger when no row exists — this never creates one,
    #   because a response arriving without a reservation would mean a request was made
    #   without reserving.
    def block_globally!(until_at:, reason:, window_status: nil, now: Time.current)
      assert_committable!

      uncached_transaction do
        budget = GithubApiBudget.lock.find_by(id: SINGLETON_ID)
        next :no_ledger if budget.nil?

        apply_block!(budget, until_at: until_at, reason: reason,
                             window_status: window_status, now: now)
      end
    end

    private

    def apply_block!(budget, until_at:, reason:, window_status:, now:)
      GithubApiBudget.connection.exec_update(
        ActiveRecord::Base.sanitize_sql_array([ BLOCK_SQL, until_at, window_status, now, SINGLETON_ID ]),
        "Github::BudgetLedger BlockGlobally"
      )

      # §11 lists "global_blocked_until set/cleared" among the budget state transitions
      # that belong at INFO. The instant is the field an operator greps for when nothing
      # is happening and nothing looks wrong.
      Rails.logger.info(event: "budget.global_block_set", reason: reason,
                        blocked_until: until_at.utc.iso8601,
                        previous_blocked_until: budget.global_blocked_until&.utc&.iso8601,
                        window_status: window_status || budget.window_status)
      :blocked
    end

    def assert_known_class!(request_class)
      return if DEBIT_SQL.key?(request_class)

      raise ArgumentError, "unknown request class #{request_class.inspect}"
    end

    # Borrowing is a fairness concept between the two enrichment classes. Asking for it
    # on a poll is a programming error, and ignoring it silently would let a mis-plumbed
    # caller believe fairness was being bypassed when it never was.
    def assert_borrowable!(request_class, borrow)
      return unless borrow && !enrichment?(request_class)

      raise ArgumentError,
            "borrowing applies to #{Request::ENRICHMENT_CLASSES.inspect}, not #{request_class.inspect}"
    end

    # The debit must be durable before the HTTP request is issued: a caller's rollback
    # must not refund a request GitHub has already counted. ActiveRecord::Base.transaction
    # joins an open transaction by default, and requires_new: true would only give a
    # savepoint, whose release is not a commit.
    #
    # joinable? rather than open?: RSpec's transactional fixtures open the example
    # transaction with joinable: false, so Active Record gives application transactions
    # a real savepoint rather than joining it. The guard therefore fires on genuine
    # application transactions in every environment and stays silent on the test
    # harness's own, with no Rails.env check anywhere.
    #
    # It also enforces the stronger architectural rule: no live GitHub request may be
    # issued from inside a database transaction, because a transaction must never span
    # network I/O.
    def assert_committable!
      transaction = GithubApiBudget.lease_connection.current_transaction
      return unless transaction.open? && transaction.joinable?

      raise Errors::NestedTransaction,
            "BudgetLedger must not run inside an application transaction: an outer " \
            "rollback would refund a request GitHub has already counted"
    end

    # Every ledger read has to see the row as it is *now*, and the Active Record query
    # cache does not guarantee that: it wraps select_all, so GithubApiBudget.find is
    # cacheable, while the raw exec_update statements this class writes with do not
    # invalidate it. A reservation's post-debit read would then populate the cache and a
    # later rollover would be handed the pre-rollover row — which is exactly how a
    # reconcile could roll the window twice and then raise.
    def uncached_transaction(&)
      GithubApiBudget.uncached { GithubApiBudget.transaction(&) }
    end

    # Pessimistic SELECT ... FOR UPDATE, not an optimistic lock_version retry.
    # Contention on this one row is the design rather than an anomaly — every outbound
    # request in the system passes through it — so optimistic locking would degrade
    # into a retry storm. The critical section is also not a compare-and-swap: it rolls
    # the window, re-derives three allowances, evaluates four ordered denial conditions,
    # and only then debits, and a zero-row conditional UPDATE could not report *why* it
    # refused. The cost is nil because the reservation runs inside the request gate, so
    # at most one process is ever in here, holding one known row for microseconds.
    #
    # The two enrichment statements take a third bind and the poll statement does not.
    # Building the binds from the same three names in the same order and dropping the nil
    # keeps one sanitize_sql_array call rather than a branch per class; share_cap is the
    # only one of the three that is ever legitimately nil.
    def debit!(request_class, now:, share_cap:, borrow:)
      binds = [ now, SINGLETON_ID, share_cap ].compact

      updated = GithubApiBudget.connection.exec_update(
        ActiveRecord::Base.sanitize_sql_array([ DEBIT_SQL.fetch(request_class), *binds ]),
        "Github::BudgetLedger Debit"
      )

      if updated != 1
        raise Errors::LedgerInvariantViolation,
              "a #{request_class} debit was rejected by the same guards that passed under the row lock"
      end

      GithubApiBudget.find(SINGLETON_ID).tap do |budget|
        log_class_exhausted(budget, request_class)
        log_share_transitions(budget, request_class, borrow: borrow)
      end
    end

    # §11 puts "class exhaustion" among the budget transitions that belong at INFO.
    #
    # Emitted from the debit that *reached* the allowance, not from denial_reason. A
    # denial recurs on every attempt — under PR 8's recurring task that is a line a minute
    # for the rest of the window, burying the stream §11 explicitly sizes. The debit that
    # takes used to allowance happens exactly once per class per window, which is what a
    # transition means.
    def log_class_exhausted(budget, request_class)
      used = class_used(budget, request_class)
      allowance = class_allowance(budget, request_class)
      return unless used == allowance

      # reset_at, not a derived instant: this reports what the ledger knows. When it is
      # nil the window has not been initialized, and the scheduler's own fallback — one
      # cadence away — is GithubApiBudget#poll_class_blocked_until's business, not a
      # number to guess at twice.
      Rails.logger.info(event: "budget.class_exhausted", request_class: request_class,
                        used: used, allowance: allowance, resource: budget.resource,
                        reset_at: budget.reset_at&.utc&.iso8601)
    end

    # The share's two transitions, emitted for the same reason and on the same terms as
    # log_class_exhausted above: from the debit that *reached* the number, so each fires
    # once per class per window instead of once per denied attempt.
    #
    # Two edges worth naming. With a guarantee of zero the INFO never fires — the
    # post-debit share is 1 and never 0 — which is correct, because nothing transitioned:
    # that class was borrowing from its first request. And under a sustained borrow the
    # INFO still fires exactly once, at the guarantee, with budget.class_exhausted
    # following later at the class cap.
    def log_share_transitions(budget, request_class, borrow:)
      return unless enrichment?(request_class)

      guarantee = Allowances.split(budget.enrichment_allowance, configuration.actor_enrichment_share)
                            .fetch(request_class)
      used = share_used(budget, request_class)

      if used == guarantee
        Rails.logger.info(event: "budget.share_exhausted", request_class: request_class,
                          share_used: used, guarantee: guarantee,
                          enrichment_used: budget.enrichment_used,
                          enrichment_allowance: budget.enrichment_allowance,
                          reset_at: budget.reset_at&.utc&.iso8601)
      elsif borrow && used > guarantee
        # DEBUG, and only when the borrow actually mattered: §11 puts per-request lines
        # there, and a quiet system would otherwise log a borrow that changed nothing on
        # every single enrichment request.
        Rails.logger.debug(event: "budget.share_borrowed", request_class: request_class,
                           share_used: used, guarantee: guarantee,
                           enrichment_used: budget.enrichment_used,
                           enrichment_allowance: budget.enrichment_allowance)
      end
    end

    # Clock-driven rollover: the stored window boundary has passed. Checked in reserve!
    # as well as reconcile!, because nothing else runs before a request — a process idle
    # across a reset must not be denied by the dead window's counters.
    def window_elapsed?(budget, now)
      budget.reset_at.present? && now >= budget.reset_at
    end

    # Header-driven rollover: GitHub says the window moved on. Distinct from the clock
    # predicate because skew between this container and GitHub can leave now < reset_at
    # locally while the response proves otherwise.
    def window_superseded?(budget, snapshot)
      budget.reset_at.present? && snapshot.reset_at.present? && snapshot.reset_at > budget.reset_at
    end

    def roll_window!(budget, now:, carry_forward: nil)
      derived = derived_allowances(budget.limit)
      carried = carried_counters(carry_forward)

      GithubApiBudget.connection.exec_update(
        ActiveRecord::Base.sanitize_sql_array([
          ROLL_WINDOW_SQL, *carried.values, now, derived.poll_allowance,
          derived.enrichment_allowance, derived.reserve, now, SINGLETON_ID
        ]),
        "Github::BudgetLedger RollWindow"
      )

      Rails.logger.info(event: "budget.window_rolled", carried_forward: carry_forward, **derived.to_log)
      log_block_cleared(budget, now: now)
      GithubApiBudget.find(SINGLETON_ID)
    end

    # ROLL_WINDOW_SQL's CASE clears a block whose instant has passed and preserves one
    # that outlives the window boundary. §11 asks for both halves of the transition, so
    # the clearing half is reported here — this is the only path that clears.
    #
    # It logs the *write*, not the moment the block stopped biting: denial_reason derives
    # blocking from the timestamp alone, so an expired block is already inert without any
    # write at all. Emitting a synthetic event when the clock passed it would be inventing
    # a transition nothing performed.
    def log_block_cleared(budget, now:)
      blocked_until = budget.global_blocked_until
      return if blocked_until.nil? || blocked_until > now

      Rails.logger.info(event: "budget.global_block_cleared",
                        blocked_until: blocked_until.utc.iso8601, cleared_by: "window_rolled")
    end

    # Zeros unless a request is being carried into the new window, in which case its own
    # class starts at one.
    def carried_counters(request_class)
      {
        poll_used: request_class == :poll ? 1 : 0,
        enrichment_used: enrichment?(request_class) ? 1 : 0,
        actor_share_used: request_class == :actor ? 1 : 0,
        repository_share_used: request_class == :repository ? 1 : 0
      }
    end

    # §10's denial conditions, in order of how actionable they are to an operator.
    # :window_uninitialized and :reserve_reached are provably disjoint — an
    # uninitialized window has a NULL remaining — so their relative order is arbitrary.
    #
    # Blocking is derived from timestamps alone, never from window_status: a
    # globally_blocked row whose timestamp had passed would otherwise be an
    # unrecoverable state, and the plan names no transition out of it.
    def denial_reason(budget, request_class, now, share_cap:)
      if budget.global_blocked_until.present? && budget.global_blocked_until > now
        :globally_blocked
      elsif enrichment?(request_class) && budget.window_initialized_at.nil?
        # §7: enrichment is ineligible until the first real poll initializes the window
        # from authoritative headers. Another application behind the same IP may have
        # spent the budget the moment it reset, so 60 remaining is never assumed.
        #
        # Keyed on the fact rather than on window_status, because the label is no longer
        # a two-valued flag: a globally blocked window that was never initialized would
        # otherwise satisfy neither this guard nor :reserve_reached (remaining is NULL),
        # and enrichment would spend its whole allowance blind the moment the block
        # expired.
        :window_uninitialized
      elsif budget.remaining.present? && budget.remaining <= budget.reserve
        # The only condition that reflects GitHub's view rather than our own counters.
        # Without it a co-tenant burning the shared IP's budget would leave our class
        # counters happily granting requests into a remaining of zero.
        :reserve_reached
      elsif class_used(budget, request_class) >= class_allowance(budget, request_class)
        :class_allowance_exhausted
      elsif share_cap && share_used(budget, request_class) >= share_cap
        # Last, and unlike :window_uninitialized versus :reserve_reached this ordering is
        # *not* arbitrary — the condition above overlaps with this one rather than being
        # disjoint from it, so the order chooses which of two true statements is reported.
        #
        # The class cap wins because it is the broader and more actionable fact: once
        # enrichment_used has reached enrichment_allowance, no share retune and no quiet
        # backlog in the other class changes anything, and naming the share would send an
        # operator to ACTOR_ENRICHMENT_SHARE when the answer is the window. It also
        # matters to callers — :class_allowance_exhausted means "no enrichment until the
        # window resets" and is already expressed by enrichment_class_blocked_until,
        # while :share_exhausted means "not this class right now" and defers nothing.
        :share_exhausted
      end
    end

    def enrichment?(request_class)
      Request::ENRICHMENT_CLASSES.include?(request_class)
    end

    def class_used(budget, request_class)
      enrichment?(request_class) ? budget.enrichment_used : budget.poll_used
    end

    def class_allowance(budget, request_class)
      enrichment?(request_class) ? budget.enrichment_allowance : budget.poll_allowance
    end

    def share_used(budget, request_class)
      request_class == :actor ? budget.actor_share_used : budget.repository_share_used
    end

    # nil for :poll — that statement carries no share bind and that class has no share
    # predicate, so `share_cap &&` in denial_reason short-circuits by construction rather
    # than by a repeated enrichment? test. A zero cap is truthy, so a zero guarantee
    # correctly denies (0 >= 0).
    #
    # Under a borrow the cap is the whole enrichment allowance rather than
    # `guarantee + the other class's unused capacity`. The two authorize exactly the same
    # reservations: actor_share_used + repository_share_used == enrichment_used is an
    # invariant of these statements, so the class guard already limits this class to
    # enrichment_allowance - other_share_used, which is what §10's phrasing computes.
    # Taking the simpler of two equivalent caps means the borrowed statement's guard
    # degenerates into the class check — the shape "only the class cap binds" should have.
    #
    # Derived from the row's *stored* enrichment_allowance, never from a fresh
    # Allowances.derive: ADR 0004 fixes the allowances at initialization and rollover, and
    # a guarantee computed from a different total than class_allowance checks against
    # could exceed it.
    def share_cap(budget, request_class, borrow:)
      return nil unless enrichment?(request_class)
      return budget.enrichment_allowance if borrow

      Allowances.split(budget.enrichment_allowance, configuration.actor_enrichment_share)
                .fetch(request_class)
    end

    # A present but different resource means the response belongs to another rate-limit
    # bucket. Refuse to reconcile anything, keep the debit, and carry on: the request
    # itself succeeded, only our accounting model does not apply to it. Folding a
    # search bucket's numbers in through LEAST would clamp us to its remaining and
    # import its 60-second reset as our window boundary, producing denials
    # indistinguishable from real exhaustion. Raising instead would let one stray URL
    # crash the poller on every attempt, which §10 forbids.
    #
    # Compared against the stored resource rather than a literal, so a future
    # authenticated configuration is a data change.
    def resource_mismatch?(budget, snapshot)
      return false if snapshot.resource.blank? || snapshot.resource == budget.resource

      Rails.logger.warn(event: "budget.resource_mismatch",
                        expected_resource: budget.resource, observed_resource: snapshot.resource)
      true
    end

    # Dispatches on reset_at rather than on window_status, and the difference is not
    # cosmetic. window_status became a three-valued label once a global block could write
    # "globally_blocked", and a block can land on a window that was never initialized — a
    # 403 carrying only Retry-After is classified :secondary_limited, its snapshot is not
    # quantitative?, so nothing here ever ran. Keying on the label then skipped this
    # branch, fell past `snapshot.reset_at == budget.reset_at` (false against nil) and
    # raised ArgumentError comparing a Time to nil — an error no rescue in the executor
    # catches, and one nothing recovers from, because both rollover predicates require
    # reset_at to be present.
    #
    # A NULL reset_at *is* what "uninitialized" means. window_status is a report for
    # operators, never a dispatch key.
    def apply_observation(budget, snapshot, now:)
      if budget.reset_at.nil?
        initialize_window!(budget, snapshot, now: now)
        log_co_tenant_usage(budget, snapshot, phase: "initialized")
        :initialized
      elsif snapshot.reset_at == budget.reset_at
        apply_monotonic!(snapshot, now: now)
        log_co_tenant_usage(budget, snapshot, phase: "updated")
        :updated
      elsif snapshot.reset_at < budget.reset_at
        # Out of order. The global serial gate makes this impossible in practice; the
        # monotonic rule is defence in depth, so it is ignored rather than applied.
        :stale_observation
      else
        raise Errors::LedgerInvariantViolation, "a superseding window failed to roll before reconciliation"
      end
    end

    def initialize_window!(budget, snapshot, now:)
      derived = derived_allowances(snapshot.limit)

      GithubApiBudget.connection.exec_update(
        ActiveRecord::Base.sanitize_sql_array([
          INITIALIZE_WINDOW_SQL, snapshot.limit, snapshot.remaining, snapshot.reset_at,
          snapshot.observed_at || now, now, derived.poll_allowance, derived.enrichment_allowance,
          derived.reserve, now, SINGLETON_ID
        ]),
        "Github::BudgetLedger InitializeWindow"
      )

      log_reset_in_past(snapshot, now: now)
      Rails.logger.info(event: "budget.window_initialized",
                        **derived.to_log, **snapshot.to_log, poll_used: budget.poll_used)
    end

    # GitHub sends x-ratelimit-reset as an instant in the future, so seeing one in the past
    # means this container's clock is ahead of GitHub's. The consequence is specific and
    # otherwise invisible: #window_elapsed? fires on the very next reservation, the window
    # rolls straight back to uninitialized, and enrichment — which §7 makes ineligible until
    # a window is initialized — never gets a single request for as long as the skew lasts.
    #
    # Reported and not acted on. Refusing to initialize would leave enrichment exactly as
    # starved while removing the one line that names why, and polling is unaffected either
    # way because an uninitialized window is precisely the state §7 grants a poll in.
    def log_reset_in_past(snapshot, now:)
      return if snapshot.reset_at > now

      Rails.logger.warn(event: "budget.window_reset_in_past",
                        reset_at: snapshot.reset_at.utc.iso8601, observed_at: now.utc.iso8601,
                        skew_seconds: (now - snapshot.reset_at).round)
    end

    # §7 and ADR 0004 both state the limitation this reports — "the ledger coordinates this
    # application only. Other software behind the same public IP can consume capacity
    # outside it" — and until now nothing in the running system evidenced it:
    # x-ratelimit-used was parsed by Github::RateLimitSnapshot and read by no one.
    #
    # divergence is what GitHub counted in this window minus what this application counted.
    # Both are window-scoped, and the debit precedes the request, so the comparison is
    # like-for-like: anything positive is capacity someone else spent.
    #
    # Reported, never applied. GitHub's used carries no request class, so folding it into
    # poll_used or enrichment_used would have to guess, and a guess breaks the invariant
    # actor_share_used + repository_share_used == enrichment_used that the fairness split
    # rests on. The guard that already acts on a co-tenant is `remaining <= reserve`, and it
    # needs no attribution to work.
    def log_co_tenant_usage(budget, snapshot, phase:)
      return if snapshot.used.nil?

      ledger_used = budget.poll_used + budget.enrichment_used
      divergence = snapshot.used - ledger_used
      return unless divergence.positive?

      fields = { phase: phase, divergence: divergence, observed_used: snapshot.used,
                 ledger_used: ledger_used, observed_remaining: snapshot.remaining,
                 reserve: budget.reserve }

      # DEBUG for the observation, which recurs on every reconciliation for as long as the
      # co-tenant is there and is a per-request line by §11's placement. INFO for the one
      # moment it becomes an operator's problem: the shared IP has taken remaining to the
      # reserve, so :reserve_reached is about to deny every class for the rest of the window
      # and the silence that follows needs a cause attached to it.
      if snapshot.remaining <= budget.reserve
        Rails.logger.info(event: "budget.co_tenant_pressure", **fields)
      else
        Rails.logger.debug(event: "budget.co_tenant_usage", **fields)
      end
    end

    def apply_monotonic!(snapshot, now:)
      GithubApiBudget.connection.exec_update(
        ActiveRecord::Base.sanitize_sql_array([
          MONOTONIC_UPDATE_SQL, snapshot.limit, snapshot.remaining, snapshot.observed_at || now,
          now, SINGLETON_ID
        ]),
        "Github::BudgetLedger Reconcile"
      )
    end

    # The limit to plan against is the last authoritative observation, falling back to
    # GitHub's documented unauthenticated limit before any header has been seen — which
    # is why rollover keeps "limit". Clamped, never raised: only boot-time validation
    # refuses a configuration, because a mid-flight header change is GitHub's business
    # and must degrade rather than crash-loop the worker.
    #
    # The source count comes from event_sources rather than from the environment (PR 9,
    # ADR 0004). Reached only from #roll_window! and #initialize_window! — the two moments
    # ADR 0004 already re-derives allowances at — so a live database read happens at most
    # twice an hour rather than once per reservation. Github::SourceAllocation documents why
    # the query is safe inside this transaction's row lock.
    def derived_allowances(observed_limit)
      derived = configuration.allowances(limit: configuration.effective_limit(observed_limit),
                                         live_source_count: allocation.live_source_count)

      log_clamp(derived) unless derived.feasible?
      derived.clamped
    end

    # The configuration's own arithmetic, with no database read at all. #bootstrap! runs
    # ahead of *every* reservation, so asking event_sources here would put a second query on
    # the hot path to write values that only matter until the first response arrives: the
    # row it inserts is uninitialized, and #initialize_window! overwrites all three
    # allowances from the observed count before enrichment may spend anything.
    def configured_allowances
      configuration.allowances.clamped
    end

    # Clamping is the runtime half of §10's startup rejection, and it has been silent since
    # PR 4 — an operator whose enrichment allowance quietly became zero because GitHub
    # reported a lower limit had nothing to grep for. WARN rather than INFO because the
    # numbers now in force are not the ones the environment asks for.
    def log_clamp(derived)
      clamped = derived.clamped

      Rails.logger.warn(event: "budget.allowances_clamped",
                        requested_poll_allowance: derived.poll_allowance,
                        requested_enrichment_allowance: derived.enrichment_allowance,
                        **clamped.to_log)
    end
  end
end
