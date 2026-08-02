module Github
  # §10's response behaviour for the three conditions that must stop *every* live
  # request, and only those.
  #
  # Distinct from Github::RetryPolicy despite the similar name: that one decides whether
  # *this request* is attempted again inside one fetch. This decides when *anything* may
  # be attempted again, by any process, in any class.
  #
  # It decides; Github::BudgetLedger records. The split exists because the ledger owns a
  # locking discipline — assert_committable!, an uncached SELECT ... FOR UPDATE, a manual
  # lock_version bump — that a second writer of that row would have to duplicate and
  # would eventually drift from. Choosing an instant needs none of it.
  #
  # What is deliberately *not* here: class exhaustion. §10 derives class blocking from
  # counters and keeps it out of the global column, because one timestamp cannot serve
  # both — enrichment spending its 40 attempts would stop polling, and polling spending
  # its 12 would stop enrichment (Appendix D item 2). A :class_allowance_exhausted denial
  # therefore writes nothing here; GithubApiBudget#poll_class_blocked_until and
  # #enrichment_class_blocked_until already express it.
  #
  # Nor is the fairness share, for the same reason one level down. §10: "Actor/repository
  # share exhaustion lives inside BudgetLedger.reserve!(:actor | :repository) and never
  # touches the global block." A :share_exhausted denial is a refusal between two
  # enrichment classes; treating it as a condition that stops polling would be absurd,
  # and #reserve_breach's allowlist is what makes that structural rather than a comment.
  class RateLimitPolicy
    # §10: "≥ 1 minute with exponential backoff when the header is absent". Also the
    # floor for a Retry-After GitHub sends that is shorter, or zero.
    MIN_BLOCK_SECONDS = 60
    # An honoured Retry-After is capped: the header is IP-scoped and stops enrichment too,
    # and enrichment has no source row to recover from a block measured in days. A capped
    # block is logged, so an operator can see the service chose not to obey literally.
    MAX_BLOCK_SECONDS = 3600

    BLOCKED_WINDOW = "globally_blocked".freeze

    # kind is the reason the block exists, and it is what §11's INFO line reports: an
    # operator staring at an hour of silence needs to know which of §10's three conditions
    # produced it.
    class Decision < Data.define(:kind, :blocked_until, :source_retry_at, :window_status)
      KINDS = %i[ none primary_rate_limit secondary_rate_limit reserve_reached ].freeze

      def self.none
        new(kind: :none, blocked_until: nil, source_retry_at: nil, window_status: nil)
      end

      def blocking? = !blocked_until.nil?

      def to_log
        { block_reason: kind, blocked_until: blocked_until&.utc&.iso8601 }.compact
      end
    end

    def initialize(ledger: BudgetLedger.new, backoff: PollBackoff.new,
                   search_ledger: SearchBudgetLedger.new)
      @ledger = ledger
      @backoff = backoff
      @search_ledger = search_ledger
    end

    # Called once per FetchResult a poll observes, including pages after the first: a rate
    # limit is a fact about the IP, not about which page happened to ask.
    #
    # Runs after the executor has returned — the gate is released and no transaction is
    # open — which is what keeps the ledger's row lock innermost.
    #
    # @param fetched [Github::FetchResult]
    # @param resource [Symbol] :core or :search — which rate-limit resource answered.
    #   It changes only the *primary* verdict: a primary exhaustion bounds the resource
    #   that reported it, so a spent Search minute must not stop polling for the hour,
    #   and Github::SearchBudgetLedger records that one locally. Secondary limits are
    #   IP-scoped whichever resource surfaced them, so they are decided here once and
    #   written to both ledgers.
    # @return [Decision]
    def apply!(fetched, now: Time.current, resource: :core)
      decision = decide(fetched, now: now, resource: resource)

      unless decision.blocking?
        # A live request that completed without a secondary limit is the evidence that the
        # IP is no longer being throttled, and §10's backoff is exponential in
        # *consecutive* limits. Asked of successful? rather than of the decision alone: a
        # 5xx or a timeout produced no verdict from GitHub about throttling, so it must
        # neither escalate the streak nor end it. A successful Search response is that
        # same evidence, which is why the streak is cleared for either resource.
        @ledger.clear_secondary_limit_streak!(now: now) if fetched.successful?
        return decision
      end

      @ledger.block_globally!(until_at: decision.blocked_until, reason: decision.kind,
                              window_status: decision.window_status, now: now)
      # The one condition that stops every live request stops the other resource too.
      if decision.kind == :secondary_rate_limit
        @search_ledger.block_until!(until_at: decision.blocked_until, now: now)
      end
      decision
    end

    private

    def decide(fetched, now:, resource: :core)
      case fetched.classification
      when :rate_limited then resource == :search ? Decision.none : primary_limit(fetched, now: now)
      when :secondary_limited then secondary_limit(fetched, now: now)
      when :budget_denied then reserve_breach(fetched, now: now)
      else Decision.none
      end
    end

    # §10: "primary rate limit exhausted (X-RateLimit-Remaining = 0) → defer to reset_at".
    #
    # The instant comes from the response that carried the limit, never from the stored
    # reset_at: that column is NULL on a fresh install and after every rollover, so
    # reading it would write NULL, denial_reason would see no block at all, and the poller
    # would spend its whole allowance re-asking a quota that is provably at zero.
    def primary_limit(fetched, now:)
      snapshot = fetched.rate_limit(observed_at: now)
      # attempt: 1 — a primary exhaustion is not escalated on the secondary streak. The
      # two conditions are unrelated: §10 attaches exponential backoff to secondary limits
      # specifically, and a quota that is provably at zero is relieved by the window
      # rolling, not by waiting longer each time.
      blocked_until = snapshot&.reset_at || fallback_instant(snapshot, now: now, attempt: 1)

      Decision.new(kind: :primary_rate_limit, blocked_until: blocked_until,
                   source_retry_at: nil, window_status: blocked_window_status)
    end

    # §10: "On any secondary-limit response: set global_blocked_until from Retry-After (or
    # ≥ 1 minute with exponential backoff when the header is absent), also update the
    # request-specific source or entity retry state, and stop all live requests."
    #
    # The source-scoped instant is not redundant with the global one. ROLL_WINDOW_SQL
    # clears the global block at the window boundary, while the source's own component
    # survives it — so a secondary limit that outlives a rollover still defers the source
    # that provoked it.
    #
    # window_status is left alone here, unlike the two reset-backed blocks. Those expire
    # exactly when the window rolls, and rollover is the transition that restores the
    # label; a secondary limit expires on an unrelated Retry-After and has no writer to
    # put the label back, so it would strand a value with no way out.
    # The streak read here is stale by construction, and acceptably so. #apply! runs after
    # the gate is released, so two responses can read the same count and compute the same
    # block. The consequence is an under-escalated block and never an over-escalated one,
    # and BLOCK_SQL's GREATEST means the loser's shorter instant cannot shorten the
    # winner's. Computing it inside the ledger under the row lock would remove the staleness
    # and cost the split this class exists for: it decides, the ledger records.
    def secondary_limit(fetched, now:)
      attempt = consecutive_secondary_limits + 1
      blocked_until = fallback_instant(fetched.rate_limit(observed_at: now), now: now, attempt: attempt)

      Decision.new(kind: :secondary_rate_limit, blocked_until: blocked_until,
                   source_retry_at: blocked_until, window_status: nil)
    end

    # §10: "usable budget has reached the global reserve" is a global condition. The other
    # three ledger denials are not: :class_allowance_exhausted is class blocking,
    # :globally_blocked is a block already in force, and :window_uninitialized is
    # enrichment-only.
    def reserve_breach(fetched, now:)
      error = fetched.error
      return Decision.none unless error.is_a?(Errors::BudgetExhausted) && error.reason == :reserve_reached

      budget = GithubApiBudget.find_by(id: GithubApiBudget::SINGLETON_ID)
      blocked_until = budget&.reset_at
      return Decision.none if blocked_until.nil?

      Decision.new(kind: :reserve_reached, blocked_until: blocked_until,
                   source_retry_at: nil, window_status: blocked_window_status)
    end

    # Retry-After may be absent, zero, negative, or unparseable. All of those mean the same
    # thing here: no usable instruction, so back off on our own terms. `now + nil` raises
    # and `now + nil.to_i` is no block at all, which is the response most likely to
    # escalate GitHub's throttling.
    #
    # A server-supplied instruction is obeyed as given (within honoured's clamp), so
    # `attempt` reaches PollBackoff only on the header-absent path — which is exactly where
    # §10 puts the exponential: "from Retry-After (or >= 1 minute with exponential backoff
    # when the header is absent)".
    def fallback_instant(snapshot, now:, attempt:)
      seconds = snapshot&.retry_after_seconds
      return now + honoured(seconds) if seconds.is_a?(Integer) && seconds.positive?

      @backoff.retry_at(attempt, now: now)
    end

    # Zero when no row exists yet: a secondary limit before the ledger is bootstrapped has
    # no history to escalate from, and PollBackoff's floor still gives it the minute §10
    # requires.
    def consecutive_secondary_limits
      GithubApiBudget.find_by(id: GithubApiBudget::SINGLETON_ID)&.consecutive_secondary_limits.to_i
    end

    def honoured(seconds)
      capped = seconds.clamp(MIN_BLOCK_SECONDS, MAX_BLOCK_SECONDS)

      if capped != seconds
        Rails.logger.info(event: "budget.retry_after_adjusted",
                          requested_seconds: seconds, honoured_seconds: capped)
      end

      capped
    end

    # Written only from active. A window that was never initialized keeps its label: the
    # block's timestamp is what stops requests, and denial_reason has always derived
    # blocking from timestamps alone precisely so that no label can strand the row.
    def blocked_window_status
      GithubApiBudget.find_by(id: GithubApiBudget::SINGLETON_ID)&.active? ? BLOCKED_WINDOW : nil
    end
  end
end
