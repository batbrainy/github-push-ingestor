module Github
  # The class-aware request budget (IMPLEMENTATION_PLAN.md §7, §10). Every outbound
  # live request from any process — poller, worker, one-shot — reserves capacity here
  # transactionally *before* execution, because the unauthenticated limit is keyed to
  # the outbound IP rather than to any one event source.
  #
  # The division of labour with PR 6 is: **the ledger enforces, the policy decides.**
  # This class refuses a reservation it has no capacity for, and it reads
  # global_blocked_until — but it never sets that column, never derives
  # poll_class_blocked_until for scheduling, and never handles a secondary limit. All
  # of that is PR 6 (§13). Fairness shares between actors and repositories are PR 7;
  # PR 4 maintains actor_share_used and repository_share_used accurately so PR 7 adds
  # predicates over data that is already correct, with no back-fill.
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

    DENIAL_REASONS = %i[
      globally_blocked window_uninitialized reserve_reached class_allowance_exhausted
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
         WHERE id = ? AND enrichment_used < enrichment_allowance
      SQL
      repository: <<~SQL.squish
        UPDATE github_api_budget
           SET enrichment_used = enrichment_used + 1,
               repository_share_used = repository_share_used + 1,
               remaining = CASE WHEN remaining IS NULL THEN NULL ELSE GREATEST(remaining - 1, 0) END,
               lock_version = lock_version + 1,
               updated_at = ?
         WHERE id = ? AND enrichment_used < enrichment_allowance
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

    def initialize(configuration: Github.configuration)
      @configuration = configuration
    end

    attr_reader :configuration

    # Debits one request attempt of the given class, transactionally, before the
    # request is performed.
    #
    # @param request_class [Symbol] :poll, :actor, or :repository
    # @return [GithubApiBudget] the row after the debit
    # @raise [Github::Errors::BudgetExhausted] carrying the denial reason
    def reserve!(request_class, now: Time.current)
      assert_known_class!(request_class)
      assert_committable!
      bootstrap!(now: now)

      budget, reason = uncached_transaction do
        budget = GithubApiBudget.lock.find(SINGLETON_ID)
        budget = roll_window!(budget, now: now) if window_elapsed?(budget, now)

        denial = denial_reason(budget, request_class, now)
        # The rollover above commits even when the reservation is refused, so the reason
        # is carried out of the transaction and raised after it: a denial must not undo
        # a window reset that has genuinely happened.
        next [ budget, denial ] if denial

        [ debit!(request_class, now: now), nil ]
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
      derived = derived_allowances(nil)

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

    private

    def assert_known_class!(request_class)
      return if DEBIT_SQL.key?(request_class)

      raise ArgumentError, "unknown request class #{request_class.inspect}"
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
    def debit!(request_class, now:)
      updated = GithubApiBudget.connection.exec_update(
        ActiveRecord::Base.sanitize_sql_array([ DEBIT_SQL.fetch(request_class), now, SINGLETON_ID ]),
        "Github::BudgetLedger Debit"
      )

      if updated != 1
        raise Errors::LedgerInvariantViolation,
              "a #{request_class} debit was rejected by the same guard that passed under the row lock"
      end

      GithubApiBudget.find(SINGLETON_ID)
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
      GithubApiBudget.find(SINGLETON_ID)
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
    def denial_reason(budget, request_class, now)
      if budget.global_blocked_until.present? && budget.global_blocked_until > now
        :globally_blocked
      elsif enrichment?(request_class) && budget.window_status == "uninitialized"
        # §7: enrichment is ineligible until the first real poll initializes the window
        # from authoritative headers. Another application behind the same IP may have
        # spent the budget the moment it reset, so 60 remaining is never assumed.
        :window_uninitialized
      elsif budget.remaining.present? && budget.remaining <= budget.reserve
        # The only condition that reflects GitHub's view rather than our own counters.
        # Without it a co-tenant burning the shared IP's budget would leave our class
        # counters happily granting requests into a remaining of zero.
        :reserve_reached
      elsif class_used(budget, request_class) >= class_allowance(budget, request_class)
        :class_allowance_exhausted
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

    def apply_observation(budget, snapshot, now:)
      if budget.window_status == "uninitialized"
        initialize_window!(budget, snapshot, now: now)
        :initialized
      elsif snapshot.reset_at == budget.reset_at
        apply_monotonic!(snapshot, now: now)
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

      Rails.logger.info(event: "budget.window_initialized",
                        **derived.to_log, **snapshot.to_log, poll_used: budget.poll_used)
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
    def derived_allowances(observed_limit)
      configuration.allowances(limit: configuration.effective_limit(observed_limit)).clamped
    end
  end
end
