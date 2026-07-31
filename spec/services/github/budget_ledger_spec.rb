require "rails_helper"

RSpec.describe Github::BudgetLedger do
  subject(:ledger) { described_class.new }

  let(:window_reset) { frozen_time + 3600 }

  # Both defined in spec/support/budget_helpers.rb, so "what an active window looks
  # like" is stated once and the executor's specs use the same definition.
  def budget = current_budget
  def active_window(**overrides) = active_budget_window(**overrides)

  def snapshot(**overrides)
    Github::RateLimitSnapshot.from_headers({
      "x-ratelimit-resource" => "core", "x-ratelimit-limit" => "60",
      "x-ratelimit-remaining" => "59", "x-ratelimit-reset" => window_reset.to_i.to_s
    }.merge(overrides.transform_keys(&:to_s)), observed_at: frozen_time)
  end

  describe "#bootstrap!" do
    # No migration and no seed creates it: db:prepare seeds only when it creates a
    # database, and db:test:prepare never seeds — a seeded row would exist in
    # development and be missing in test.
    it "creates the singleton row, which nothing else in the application seeds" do
      expect { ledger.bootstrap!(now: frozen_time) }.to change(GithubApiBudget, :count).from(0).to(1)
    end

    it "opens the row uninitialized with the derived allowances and nothing spent" do
      ledger.bootstrap!(now: frozen_time)

      expect(budget).to have_attributes(
        window_status: "uninitialized", poll_allowance: 12, enrichment_allowance: 40,
        reserve: 8, poll_used: 0, enrichment_used: 0, limit: nil, remaining: nil, reset_at: nil
      )
    end

    # Two processes starting cold race here, and ON CONFLICT DO NOTHING is what makes
    # the loser a no-op rather than a RecordNotUnique that would poison a transaction.
    it "tolerates a row another process created first" do
      ledger.bootstrap!(now: frozen_time)

      expect { ledger.bootstrap!(now: frozen_time) }.not_to change(GithubApiBudget, :count)
    end
  end

  describe "#reserve!" do
    it "debits the poll counter before the request is performed" do
      active_window

      expect { ledger.reserve!(:poll, now: frozen_time) }
        .to change { budget.poll_used }.from(0).to(1)
    end

    it "debits both the class counter and the per-entity share for enrichment" do
      active_window

      ledger.reserve!(:actor, now: frozen_time)
      ledger.reserve!(:repository, now: frozen_time)

      expect(budget).to have_attributes(enrichment_used: 2, actor_share_used: 1, repository_share_used: 1)
    end

    it "records each enrichment request against its own class share" do
      active_window

      3.times { ledger.reserve!(:actor, now: frozen_time) }

      expect(budget).to have_attributes(actor_share_used: 3, repository_share_used: 0)
    end

    it "decrements the local remaining estimate, so a failure is spent against it too" do
      active_window(remaining: 55)

      expect { ledger.reserve!(:poll, now: frozen_time) }.to change { budget.remaining }.from(55).to(54)
    end

    it "refuses an unknown request class rather than debiting nothing silently" do
      expect { ledger.reserve!(:search, now: frozen_time) }.to raise_error(ArgumentError, /search/)
    end

    it "creates the ledger row on first use, so a cold start needs no seeding step" do
      expect { ledger.reserve!(:poll, now: frozen_time) }.to change(GithubApiBudget, :count).from(0).to(1)
    end
  end

  describe "class isolation (plan §10)" do
    # §10: enrichment exhausting its forty attempts never stops polling, and polling
    # exhausting its twelve never stops enrichment.
    it "denies polling once its allowance is spent, without touching enrichment" do
      active_window(poll_used: 12)

      expect { ledger.reserve!(:poll, now: frozen_time) }
        .to raise_error(Github::Errors::BudgetExhausted, /class_allowance_exhausted/)
      expect { ledger.reserve!(:actor, now: frozen_time) }.not_to raise_error
    end

    it "denies enrichment once its allowance is spent, without touching polling" do
      active_window(enrichment_used: 40)

      expect { ledger.reserve!(:actor, now: frozen_time) }
        .to raise_error(Github::Errors::BudgetExhausted, /class_allowance_exhausted/)
      expect { ledger.reserve!(:poll, now: frozen_time) }.not_to raise_error
    end

    it "denies both classes once remaining has reached the global reserve" do
      active_window(remaining: 8, reserve: 8)

      %i[ poll actor repository ].each do |request_class|
        expect { ledger.reserve!(request_class, now: frozen_time) }
          .to raise_error(Github::Errors::BudgetExhausted, /reserve_reached/)
      end
    end

    # This class enforces the column; Github::RateLimitPolicy decides when it is set.
    # Keeping the two apart means the policy never reopens the ledger's
    # critical section.
    it "honours a global block it never sets itself" do
      active_window(global_blocked_until: frozen_time + 60)

      expect { ledger.reserve!(:poll, now: frozen_time) }
        .to raise_error(Github::Errors::BudgetExhausted, /globally_blocked/)
    end

    it "grants again once an expired global block has passed" do
      active_window(global_blocked_until: frozen_time - 1)

      expect { ledger.reserve!(:poll, now: frozen_time) }.not_to raise_error
    end

    it "names only the documented denial reasons" do
      expect(described_class::DENIAL_REASONS)
        .to contain_exactly(:globally_blocked, :window_uninitialized, :reserve_reached,
                            :class_allowance_exhausted, :share_exhausted)
    end
  end

  describe "the per-window bootstrap (plan §7, §10)" do
    # §7: the first canonical page-one poll IS the bootstrap. Spending an extra request
    # to discover the quota would waste one of sixty.
    it "allows the first poll while the window is uninitialized, and counts it" do
      ledger.bootstrap!(now: frozen_time)

      ledger.reserve!(:poll, now: frozen_time)

      expect(budget).to have_attributes(poll_used: 1, window_status: "uninitialized")
    end

    # §7: another application behind the same IP may have spent the budget the moment
    # it reset, so 60 remaining is never assumed.
    it "refuses enrichment until a real response has initialized the window" do
      ledger.bootstrap!(now: frozen_time)

      %i[ actor repository ].each do |request_class|
        expect { ledger.reserve!(request_class, now: frozen_time) }
          .to raise_error(Github::Errors::BudgetExhausted, /window_uninitialized/)
      end
    end

    # PostgreSQL's GREATEST ignores NULL, so GREATEST(NULL - 1, 0) is 0 — which would
    # turn an un-bootstrapped remaining into a permanent reserve breach that denies
    # every request, including the bootstrap poll that could have refreshed it.
    it "leaves an unobserved remaining null rather than collapsing it to zero" do
      ledger.bootstrap!(now: frozen_time)

      ledger.reserve!(:poll, now: frozen_time)

      expect(budget.remaining).to be_nil
    end

    it "opens the window from the first response's headers and keeps that poll spent" do
      ledger.bootstrap!(now: frozen_time)
      ledger.reserve!(:poll, now: frozen_time)

      expect(ledger.reconcile!(snapshot, now: frozen_time)).to eq(:initialized)
      expect(budget).to have_attributes(
        window_status: "active", limit: 60, remaining: 59, reset_at: window_reset,
        window_initialized_at: frozen_time, poll_used: 1
      )
    end

    it "lets enrichment spend only after the window is active" do
      ledger.bootstrap!(now: frozen_time)
      ledger.reserve!(:poll, now: frozen_time)
      ledger.reconcile!(snapshot, now: frozen_time)

      expect { ledger.reserve!(:actor, now: frozen_time) }.not_to raise_error
    end

    # The IP co-tenant case §7 names explicitly.
    it "adopts a low observed remaining rather than assuming a fresh sixty" do
      ledger.bootstrap!(now: frozen_time)
      ledger.reserve!(:poll, now: frozen_time)

      ledger.reconcile!(snapshot("x-ratelimit-remaining" => "3"), now: frozen_time)

      expect(budget.remaining).to eq(3)
    end
  end

  describe "window rollover" do
    it "resets the counters when the stored window boundary has passed" do
      active_window(poll_used: 12, enrichment_used: 40, actor_share_used: 20, repository_share_used: 20)

      ledger.reserve!(:poll, now: window_reset + 1)

      expect(budget).to have_attributes(
        poll_used: 1, enrichment_used: 0, actor_share_used: 0, repository_share_used: 0,
        window_status: "uninitialized"
      )
    end

    # A dead window's remaining of 3 against a reserve of 8 would deny every request
    # forever, including the bootstrap poll that is the only thing able to refresh it.
    it "clears a stale remaining, which would otherwise deadlock the ledger permanently" do
      active_window(remaining: 3, reserve: 8)

      expect { ledger.reserve!(:poll, now: window_reset + 1) }.not_to raise_error
      expect(budget.remaining).to be_nil
    end

    it "keeps the last observed limit, which feeds the next allowance derivation" do
      active_window(limit: 60)

      ledger.reserve!(:poll, now: window_reset + 1)

      expect(budget.limit).to eq(60)
    end

    # A primary-exhaustion block was set to the reset that has now passed; a
    # secondary-limit block can outlive it, and §10 keeps the two distinct.
    it "clears an expired global block but preserves one that outlives the reset" do
      active_window(global_blocked_until: window_reset - 60)
      ledger.reserve!(:poll, now: window_reset + 1)
      expect(budget.global_blocked_until).to be_nil

      active_window(global_blocked_until: window_reset + 600)
      suppress(Github::Errors::BudgetExhausted) { ledger.reserve!(:poll, now: window_reset + 1) }
      expect(budget.global_blocked_until).to eq(window_reset + 600)
    end

    # The rollover genuinely happened, so it must survive even when the reservation
    # that discovered it is refused.
    it "commits the reset even when the reservation is then denied" do
      active_window(poll_used: 12, global_blocked_until: window_reset + 600)

      suppress(Github::Errors::BudgetExhausted) { ledger.reserve!(:poll, now: window_reset + 1) }

      expect(budget.poll_used).to eq(0)
    end
  end

  describe "#reconcile!" do
    # §7: headers are authoritative but may arrive out of order, so within one window
    # remaining only ever moves down.
    it "takes the lower of the local estimate and the observed value" do
      active_window(remaining: 20)

      ledger.reconcile!(snapshot("x-ratelimit-remaining" => "50"), now: frozen_time)

      expect(budget.remaining).to eq(20)
    end

    it "adopts an observed value lower than the local estimate" do
      active_window(remaining: 50)

      ledger.reconcile!(snapshot("x-ratelimit-remaining" => "20"), now: frozen_time)

      expect(budget.remaining).to eq(20)
    end

    # Clamping a new window's 59 down to the old window's 2 would starve enrichment for
    # a full hour, so rollover has to happen before any LEAST is applied.
    it "rolls the window before reconciling when the headers show a later reset" do
      active_window(remaining: 2, reset_at: window_reset)

      ledger.reconcile!(
        snapshot("x-ratelimit-reset" => (window_reset + 3600).to_i.to_s, "x-ratelimit-remaining" => "59"),
        now: frozen_time
      )

      expect(budget).to have_attributes(remaining: 59, reset_at: window_reset + 3600, window_status: "active")
    end

    it "ignores an observation from a window that has already been superseded" do
      active_window(remaining: 30)

      result = ledger.reconcile!(
        snapshot("x-ratelimit-reset" => (window_reset - 3600).to_i.to_s, "x-ratelimit-remaining" => "1"),
        now: frozen_time
      )

      expect(result).to eq(:stale_observation)
      expect(budget.remaining).to eq(30)
    end

    # Folding another bucket's numbers in would clamp us to its remaining and import its
    # 60-second reset as our window boundary, producing denials that look exactly like
    # real exhaustion. Raising instead would crash-loop the poller, which §10 forbids.
    it "refuses to reconcile a response from a different rate-limit resource" do
      active_window(remaining: 50, limit: 60)

      result = ledger.reconcile!(
        snapshot("x-ratelimit-resource" => "search", "x-ratelimit-remaining" => "1"), now: frozen_time
      )

      expect(result).to eq(:resource_mismatch)
      expect(budget).to have_attributes(remaining: 50, limit: 60, reset_at: window_reset)
    end

    it "treats a missing resource header as this application's own, not as a mismatch" do
      active_window(remaining: 50)

      expect(ledger.reconcile!(snapshot("x-ratelimit-resource" => nil), now: frozen_time)).to eq(:updated)
    end

    it "does nothing for a response carrying no rate-limit headers" do
      active_window(remaining: 50)

      result = ledger.reconcile!(
        Github::RateLimitSnapshot.from_headers({}, observed_at: frozen_time), now: frozen_time
      )

      expect(result).to eq(:partial_headers)
      expect(budget.remaining).to eq(50)
    end

    it "does nothing when a transport failure produced no snapshot at all" do
      active_window

      expect(ledger.reconcile!(nil, now: frozen_time)).to eq(:no_headers)
    end

    # A response with no reservation behind it would mean a request was made without
    # reserving, which is the invariant the whole class exists to hold.
    it "never creates the ledger row, because only a reservation may" do
      expect(ledger.reconcile!(snapshot, now: frozen_time)).to eq(:no_ledger)
      expect(GithubApiBudget.count).to eq(0)
    end

    # Otherwise reconciliation would zero the bootstrap poll's debit and the window
    # would go on to permit sixty-one requests.
    it "does not reset the counters while initializing a window for the first time" do
      ledger.bootstrap!(now: frozen_time)
      ledger.reserve!(:poll, now: frozen_time)

      ledger.reconcile!(snapshot, now: frozen_time)

      expect(budget.poll_used).to eq(1)
    end
  end

  describe "a window that moves on while a request is in flight" do
    let(:next_window) { window_reset + 3600 }

    def superseding_snapshot
      snapshot("x-ratelimit-reset" => next_window.to_i.to_s, "x-ratelimit-remaining" => "59")
    end

    # The Active Record query cache wraps select_all, so GithubApiBudget.find is
    # cacheable — while the raw exec_update statements this class writes with do not
    # invalidate it. A reservation's post-debit read would populate the cache, and the
    # rollover that followed would be handed the pre-rollover row: the window would roll
    # twice and then fall through apply_observation's branches and raise.
    it "reads the ledger uncached, so a rollover is never handed a pre-rollover row" do
      active_window

      ActiveRecord::Base.cache do
        ledger.reserve!(:poll, now: window_reset - 1)

        expect(ledger.reconcile!(superseding_snapshot, request_class: :poll, now: window_reset + 1))
          .to eq(:initialized)
      end
    end

    it "emits one window-roll transition when the response advances the window" do
      active_window
      ledger.reserve!(:poll, now: window_reset - 1)

      rolls = 0
      allow(Rails.logger).to receive(:info) { |payload| rolls += 1 if payload[:event] == "budget.window_rolled" }

      ledger.reconcile!(superseding_snapshot, request_class: :poll, now: window_reset + 1)

      expect(rolls).to eq(1)
    end

    # The request was reserved against the window that has just ended, but a superseding
    # reset_at is GitHub saying it counted the request in the new one. Zeroing the
    # counters outright would let this window issue one more request than GitHub honours.
    it "carries the in-flight reservation into the window GitHub counted it in" do
      active_window
      ledger.reserve!(:poll, now: window_reset - 1)

      ledger.reconcile!(superseding_snapshot, request_class: :poll, now: window_reset + 1)

      expect(budget).to have_attributes(poll_used: 1, window_status: "active",
                                        reset_at: next_window, remaining: 59)
    end

    it "carries an enrichment request into its own class and share" do
      active_window
      ledger.reserve!(:repository, now: window_reset - 1)

      ledger.reconcile!(superseding_snapshot, request_class: :repository, now: window_reset + 1)

      expect(budget).to have_attributes(enrichment_used: 1, repository_share_used: 1,
                                        actor_share_used: 0, poll_used: 0)
    end

    # A caller with nothing in flight — a future /status refresh — must not invent a debit.
    it "carries nothing when no request produced the response" do
      active_window
      ledger.reserve!(:poll, now: window_reset - 1)

      ledger.reconcile!(superseding_snapshot, now: window_reset + 1)

      expect(budget.poll_used).to eq(0)
    end

    # The clock-driven rollover inside reserve! has no in-flight request to carry, so it
    # still starts the window clean.
    it "still starts a clean window when the rollover happens before a reservation" do
      active_window(poll_used: 12, enrichment_used: 40)

      ledger.reserve!(:poll, now: window_reset + 1)

      expect(budget).to have_attributes(poll_used: 1, enrichment_used: 0)
    end
  end

  # §10's three truly-global conditions. This class records the block;
  # Github::RateLimitPolicy decides which condition warrants one and until when.
  describe "#block_globally!" do
    it "records the instant and refuses every class until it passes" do
      active_window
      ledger.block_globally!(until_at: frozen_time + 900, reason: :primary_rate_limit, now: frozen_time)

      expect(budget.global_blocked_until).to eq(frozen_time + 900)
      expect { ledger.reserve!(:poll, now: frozen_time) }
        .to raise_error(Github::Errors::BudgetExhausted) { |error| expect(error.reason).to eq(:globally_blocked) }
    end

    it "lets requests through again once the instant has passed" do
      active_window
      ledger.block_globally!(until_at: frozen_time + 60, reason: :secondary_rate_limit, now: frozen_time)

      expect { ledger.reserve!(:poll, now: frozen_time + 61) }.not_to raise_error
    end

    # GREATEST, and PostgreSQL ignoring NULL is the feature here rather than the hazard
    # DEBIT_SQL's comment warns about: with nothing stored it takes the new instant, and
    # with something stored it takes the later of the two. The global gate orders requests,
    # not the post-response writes that follow them, so a short block landing after a long
    # one is reachable — and letting it win would resume polling into an exhausted quota.
    it "only ever moves a block later" do
      active_window
      ledger.block_globally!(until_at: frozen_time + 3600, reason: :primary_rate_limit, now: frozen_time)
      ledger.block_globally!(until_at: frozen_time + 60, reason: :secondary_rate_limit, now: frozen_time)

      expect(budget.global_blocked_until).to eq(frozen_time + 3600)
    end

    it "labels the window only when asked to" do
      active_window

      ledger.block_globally!(until_at: frozen_time + 60, reason: :secondary_rate_limit, now: frozen_time)
      expect(budget).to be_active

      ledger.block_globally!(until_at: frozen_time + 3600, reason: :primary_rate_limit,
                             window_status: "globally_blocked", now: frozen_time)
      expect(budget).to be_globally_blocked
    end

    # The same discipline every other statement in this class keeps: this is not an Active
    # Record save, so a stale in-memory row must still raise rather than clobber the
    # counters on a later write.
    it "bumps lock_version, so a stale row still raises" do
      active_window
      stale = GithubApiBudget.find(described_class::SINGLETON_ID)

      ledger.block_globally!(until_at: frozen_time + 60, reason: :secondary_rate_limit, now: frozen_time)

      expect { stale.update!(reserve: 9) }.to raise_error(ActiveRecord::StaleObjectError)
    end

    it "creates no row, because a response without a reservation would mean an unreserved request" do
      expect(ledger.block_globally!(until_at: frozen_time + 60, reason: :secondary_rate_limit,
                                    now: frozen_time)).to eq(:no_ledger)
      expect(GithubApiBudget.count).to eq(0)
    end

    # Same rule as every other write here: no live request may be issued from inside a
    # transaction, so no ledger write may run inside one either.
    it "refuses to run inside an application transaction" do
      active_window

      expect do
        ActiveRecord::Base.transaction(joinable: true) do
          ledger.block_globally!(until_at: frozen_time + 60, reason: :secondary_rate_limit, now: frozen_time)
        end
      end.to raise_error(Github::Errors::NestedTransaction)
    end
  end

  # The count §10's exponential backoff escalates from. It is written here, under the same
  # row lock that writes the block it feeds, and read by Github::RateLimitPolicy.
  describe "the consecutive-secondary-limit streak" do
    def block(reason, until_at: frozen_time + 60)
      ledger.block_globally!(until_at: until_at, reason: reason, now: frozen_time)
    end

    it "counts a secondary limit" do
      active_window

      3.times { block(:secondary_rate_limit) }

      expect(current_budget.consecutive_secondary_limits).to eq(3)
    end

    # A primary exhaustion and a reserve breach are conditions of the budget window, not
    # evidence that GitHub is throttling this IP. Counting them would escalate a secondary
    # block from a run that contained no secondary limits.
    it "ignores the two block reasons that are not secondary limits" do
      active_window

      block(:primary_rate_limit, until_at: frozen_time + 3600)
      block(:reserve_reached, until_at: frozen_time + 3600)

      expect(current_budget.consecutive_secondary_limits).to eq(0)
    end

    describe "#clear_secondary_limit_streak!" do
      it "ends a run and reports that it did" do
        active_window
        2.times { block(:secondary_rate_limit) }

        expect(ledger.clear_secondary_limit_streak!(now: frozen_time)).to eq(:cleared)
        expect(current_budget.consecutive_secondary_limits).to eq(0)
      end

      # The common case by an enormous margin: every successful request on a service that
      # has never been throttled. It must cost one statement that matches nothing rather
      # than a read, a lock, and a write.
      it "is a silent no-op when there is no run" do
        before_version = active_window.lock_version

        expect(ledger.clear_secondary_limit_streak!(now: frozen_time)).to eq(:unchanged)
        expect(current_budget.lock_version).to eq(before_version)
      end

      it "does nothing when no row exists" do
        expect(ledger.clear_secondary_limit_streak!(now: frozen_time)).to eq(:unchanged)
        expect(GithubApiBudget.count).to eq(0)
      end

      it "refuses to run inside an application transaction" do
        active_window

        expect do
          ActiveRecord::Base.transaction(joinable: true) { ledger.clear_secondary_limit_streak!(now: frozen_time) }
        end.to raise_error(Github::Errors::NestedTransaction)
      end
    end

    # §10 calls secondary limits IP-scoped, which is a different scope from the primary
    # window ROLL_WINDOW_SQL resets. Zeroing the streak at the boundary would hand a
    # persistently throttled IP a fresh 60-second block every hour.
    it "survives a window rollover" do
      active_window
      2.times { block(:secondary_rate_limit) }

      ledger.reserve!(:poll, now: frozen_time + 3601)

      expect(current_budget).to have_attributes(consecutive_secondary_limits: 2,
                                                window_status: "uninitialized")
    end

    # The counters the ledger reserves against are untouched by either write, which is why
    # neither can return capacity a request already spent.
    it "leaves the reservation counters alone" do
      active_window
      ledger.reserve!(:poll, now: frozen_time)

      block(:secondary_rate_limit)
      ledger.clear_secondary_limit_streak!(now: frozen_time)

      expect(current_budget).to have_attributes(poll_used: 1, enrichment_used: 0,
                                                actor_share_used: 0, repository_share_used: 0)
    end
  end

  # Both guards used to key on the window_status string. That was safe while the column
  # held two values in practice; it stopped being safe once a global block could write a
  # third, so each now keys on the fact it actually means.
  describe "a global block over a window that was never initialized" do
    before do
      ledger.bootstrap!(now: frozen_time)
      budget.update!(window_status: "globally_blocked", global_blocked_until: frozen_time + 60)
    end

    # Dispatching on the label sent this response past the initialize branch, past an
    # equality test against nil, and into `snapshot.reset_at < nil` — an ArgumentError no
    # rescue in the executor catches, on a row neither rollover predicate could ever fix
    # because reset_at was NULL. Permanently.
    it "still initializes the window from the next good response" do
      expect(ledger.reconcile!(snapshot, request_class: :poll, now: frozen_time + 61))
        .to eq(:initialized)
      expect(budget).to be_active
    end

    # §7: enrichment is ineligible until the window has been initialized from authoritative
    # headers — "never assume 60 remaining". A third label must not become a way past that.
    it "still refuses enrichment, whatever the label says" do
      expect { ledger.reserve!(:actor, now: frozen_time + 61) }
        .to raise_error(Github::Errors::BudgetExhausted) { |error| expect(error.reason).to eq(:window_uninitialized) }
    end
  end

  describe "failures stay spent (plan §7)" do
    # The guarantee is structural: there is no code path that gives a request back.
    #
    # #clear_secondary_limit_streak! writes one column, consecutive_secondary_limits, which
    # no reservation reads and no counter derives from. It cannot return capacity for the
    # same reason #block_globally! cannot: neither touches poll_used, enrichment_used, or
    # either share counter.
    it "exposes no way to credit a reservation back" do
      expect(described_class.instance_methods(false)).to contain_exactly(
        :reserve!, :reconcile!, :bootstrap!, :block_globally!, :clear_secondary_limit_streak!,
        :configuration, :allocation
      )
    end

    # The allowlist above catches a method appearing; this catches the specific method
    # that would break the guarantee, however it were named. #block_globally! only ever
    # moves an instant later, so adding it left the property intact.
    it "names no operation that could give a request back" do
      expect(described_class.instance_methods(false).grep(/credit|refund|release|restore/)).to be_empty
    end

    it "keeps the debit when the request fails without any response headers" do
      active_window
      ledger.reserve!(:poll, now: frozen_time)

      ledger.reconcile!(nil, now: frozen_time)

      expect(budget.poll_used).to eq(1)
    end

    # §10's corrected 304 accounting: an unauthenticated 304 consumes quota, so the
    # reservation stays debited and only the local estimate is reconciled.
    it "keeps the debit for a 304, which consumes quota unauthenticated" do
      active_window(remaining: 56)
      ledger.reserve!(:poll, now: frozen_time)

      ledger.reconcile!(snapshot("x-ratelimit-remaining" => "55"), now: frozen_time)

      expect(budget).to have_attributes(poll_used: 1, remaining: 55)
    end

    # ActiveRecord::Base.transaction joins an open transaction by default, so a
    # caller's rollback would refund a request GitHub has already counted.
    it "refuses to run inside an application transaction" do
      active_window

      expect {
        ActiveRecord::Base.transaction { ledger.reserve!(:poll, now: frozen_time) }
      }.to raise_error(Github::Errors::NestedTransaction, /already counted/)
    end

    # RSpec's own fixture transaction is opened joinable: false, which is why the guard
    # tests joinability rather than openness and needs no Rails.env check.
    it "stays silent inside the test harness's own non-joinable transaction" do
      active_window

      expect { ledger.reserve!(:poll, now: frozen_time) }.not_to raise_error
    end
  end

  describe "allowance derivation" do
    it "writes the formula's allowances when it opens a window" do
      ledger.bootstrap!(now: frozen_time)
      ledger.reserve!(:poll, now: frozen_time)
      ledger.reconcile!(snapshot, now: frozen_time)

      expect(budget).to have_attributes(poll_allowance: 12, enrichment_allowance: 40, reserve: 8)
    end

    # A limit lower than the configured default is GitHub's business, not an operator
    # error: polling keeps its allowance, enrichment takes the loss, and nothing raises.
    it "clamps rather than raising when the observed limit cannot fund the formula" do
      ledger.bootstrap!(now: frozen_time)
      ledger.reserve!(:poll, now: frozen_time)

      ledger.reconcile!(snapshot("x-ratelimit-limit" => "15", "x-ratelimit-remaining" => "14"),
                        now: frozen_time)

      expect(budget).to have_attributes(poll_allowance: 7, enrichment_allowance: 0, limit: 15)
    end

    # PR 4 clamped silently, and an operator whose enrichment allowance had become zero
    # because GitHub reported a lower limit had nothing to grep for.
    it "reports the clamp, because the numbers in force are no longer the configured ones" do
      allow(Rails.logger).to receive(:warn)
      ledger.bootstrap!(now: frozen_time)
      ledger.reserve!(:poll, now: frozen_time)

      ledger.reconcile!(snapshot("x-ratelimit-limit" => "15", "x-ratelimit-remaining" => "14"),
                        now: frozen_time)

      expect(Rails.logger).to have_received(:warn).with(
        hash_including(event: "budget.allowances_clamped",
                       requested_poll_allowance: 12, requested_enrichment_allowance: -5,
                       poll_allowance: 7, enrichment_allowance: 0)
      )
    end

    # The clamp's floor, from the ledger's side. Without it the observed limit of 4 derives
    # poll_allowance = 0, every poll is then denied :class_allowance_exhausted, and no
    # request can ever observe a better limit again — including the next window's, since
    # rollover re-derives from the stored one.
    it "keeps a poll attempt alive at a limit the reserve alone exhausts, or nothing recovers" do
      ledger.bootstrap!(now: frozen_time)
      ledger.reserve!(:poll, now: frozen_time)
      ledger.reconcile!(snapshot("x-ratelimit-limit" => "4", "x-ratelimit-remaining" => "3"),
                        now: frozen_time)

      expect(budget).to have_attributes(poll_allowance: 1, enrichment_allowance: 0, limit: 4)
    end

    it "recovers the full allowance from the next window that reports a healthy limit" do
      ledger.bootstrap!(now: frozen_time)
      ledger.reserve!(:poll, now: frozen_time)
      ledger.reconcile!(snapshot("x-ratelimit-limit" => "4", "x-ratelimit-remaining" => "3"),
                        now: frozen_time)

      # The window rolls, the surviving attempt polls, and its headers restore the formula.
      later = window_reset + 1
      ledger.reserve!(:poll, now: later)
      ledger.reconcile!(Github::RateLimitSnapshot.from_headers(
        { "x-ratelimit-resource" => "core", "x-ratelimit-limit" => "60",
          "x-ratelimit-remaining" => "59", "x-ratelimit-reset" => (later + 3600).to_i.to_s },
        observed_at: later
      ), now: later)

      expect(budget).to have_attributes(poll_allowance: 12, enrichment_allowance: 40, limit: 60)
    end
  end

  # ADR 0004 assigned this to PR 9 by name: the allowance formula's source count comes from
  # event_sources at runtime, while boot-time validation keeps using the environment so it
  # stays safe to run before migrations.
  describe "the runtime source count (plan §10, ADR 0004)" do
    def live_sources(count)
      count.times { create_event_source(source_type: "github_public_events") }
    end

    it "derives the poll allowance from the rows that exist when a window opens" do
      live_sources(2)
      ledger.bootstrap!(now: frozen_time)
      ledger.reserve!(:poll, now: frozen_time)

      ledger.reconcile!(snapshot, now: frozen_time)

      expect(budget).to have_attributes(poll_allowance: 24, enrichment_allowance: 28)
    end

    it "re-derives it at rollover, so an added source takes effect within the hour" do
      active_window
      live_sources(2)

      ledger.reserve!(:poll, now: window_reset + 1)

      expect(budget).to have_attributes(poll_allowance: 24, enrichment_allowance: 28)
    end

    # #bootstrap! runs ahead of every reservation, so asking event_sources there would put a
    # second query on the hot path to write values the first response overwrites anyway.
    it "leaves the bootstrap row on the configured count, which the first response replaces" do
      live_sources(2)

      ledger.bootstrap!(now: frozen_time)

      expect(budget).to have_attributes(poll_allowance: 12, enrichment_allowance: 40)
    end

    it "ignores a disabled or failed source, which will never spend a poll attempt" do
      live_sources(1)
      create_event_source(source_type: "github_public_events", enabled: false)
      create_event_source(source_type: "github_public_events", status: "failed")

      ledger.bootstrap!(now: frozen_time)
      ledger.reserve!(:poll, now: frozen_time)
      ledger.reconcile!(snapshot, now: frozen_time)

      expect(budget).to have_attributes(poll_allowance: 12, enrichment_allowance: 40)
    end
  end

  describe "fairness shares (plan §10)" do
    # §10's reason for the split, in one example: one observed live page held ~92
    # repositories against ~89 actors, so a repository-first policy would spend the whole
    # hourly allowance before a single actor was enriched.
    it "stops a repository flood at its guarantee, leaving the actor share untouched" do
      active_window

      20.times { ledger.reserve!(:repository, now: frozen_time) }

      expect { ledger.reserve!(:repository, now: frozen_time) }
        .to raise_error(Github::Errors::BudgetExhausted, /share_exhausted/)
      expect { ledger.reserve!(:actor, now: frozen_time) }.not_to raise_error
    end

    it "grants an actor reservation right up to its guarantee" do
      active_window(actor_share_used: 19, enrichment_used: 19)

      expect { ledger.reserve!(:actor, now: frozen_time) }
        .to change { budget.actor_share_used }.from(19).to(20)
    end

    it "refuses the next one while the caller has not reported the other class quiet" do
      active_window(actor_share_used: 20, enrichment_used: 20)

      expect { ledger.reserve!(:actor, now: frozen_time) }
        .to raise_error(Github::Errors::BudgetExhausted, /share_exhausted/)
    end

    it "spends nothing when it refuses a share, so a denied reservation costs no quota" do
      active_window(actor_share_used: 20, enrichment_used: 20)

      expect { suppress(Github::Errors::BudgetExhausted) { ledger.reserve!(:actor, now: frozen_time) } }
        .not_to change { budget.enrichment_used }.from(20)
    end

    it "grants the same reservation once the caller reports no eligible repository candidate" do
      active_window(actor_share_used: 20, enrichment_used: 20)

      expect { ledger.reserve!(:actor, now: frozen_time, borrow: true) }
        .to change { budget.actor_share_used }.from(20).to(21)
    end

    # The plan's phrasing is "borrow the other's unused capacity", and capping at the whole
    # enrichment allowance authorizes exactly that set: actor_share_used +
    # repository_share_used == enrichment_used is an invariant of the debit statements, so
    # the class guard already limits a borrower to allowance - other_share_used.
    it "lets a borrowing class spend the whole enrichment allowance and not one request more" do
      active_window(actor_share_used: 20, repository_share_used: 5, enrichment_used: 25)

      15.times { ledger.reserve!(:actor, now: frozen_time, borrow: true) }

      expect(budget).to have_attributes(actor_share_used: 35, repository_share_used: 5, enrichment_used: 40)
      expect { ledger.reserve!(:actor, now: frozen_time, borrow: true) }
        .to raise_error(Github::Errors::BudgetExhausted, /class_allowance_exhausted/)
    end

    # The ordering is not arbitrary: both conditions are true here, and naming the share
    # would send an operator to ACTOR_ENRICHMENT_SHARE when the answer is the window.
    it "names the class allowance rather than the share once the whole budget is gone" do
      active_window(actor_share_used: 40, enrichment_used: 40)

      expect { ledger.reserve!(:actor, now: frozen_time) }
        .to raise_error(Github::Errors::BudgetExhausted, /class_allowance_exhausted/)
    end

    it "never applies a share to a poll, which has none to spend" do
      active_window(actor_share_used: 40, repository_share_used: 40)

      expect { ledger.reserve!(:poll, now: frozen_time) }.to change { budget.poll_used }.from(0).to(1)
    end

    it "derives the guarantees from the configured share rather than from a fixed half" do
      quarter = described_class.new(configuration: configuration_with(ACTOR_ENRICHMENT_SHARE: "0.25"))
      active_window(actor_share_used: 10, repository_share_used: 10, enrichment_used: 20)

      expect { quarter.reserve!(:actor, now: frozen_time) }
        .to raise_error(Github::Errors::BudgetExhausted, /share_exhausted/)
      expect { quarter.reserve!(:repository, now: frozen_time) }.not_to raise_error
    end

    # A zero guarantee is a legal operating point rather than a broken configuration:
    # §10 gates borrowing on the other class having no eligible candidate, not on its
    # counters, so "repository first, actors during the quiet periods" is expressible.
    it "gives a zero-guarantee class nothing on its own and everything under a borrow" do
      starved = described_class.new(configuration: configuration_with(ACTOR_ENRICHMENT_SHARE: "0.0"))
      active_window

      expect { starved.reserve!(:actor, now: frozen_time) }
        .to raise_error(Github::Errors::BudgetExhausted, /share_exhausted/)
      expect { starved.reserve!(:actor, now: frozen_time, borrow: true) }.not_to raise_error
    end

    it "refuses to borrow on behalf of a poll, which is a programming error and not a denial" do
      active_window

      expect { ledger.reserve!(:poll, now: frozen_time, borrow: true) }
        .to raise_error(ArgumentError, /poll/)
    end

    # The invariant the borrow cap rests on: capping a borrower at enrichment_allowance is
    # equivalent to §10's "the other's unused capacity" only because the two shares always
    # account for exactly the class counter. A debit that bumped one without the other
    # would silently widen every borrow.
    it "keeps the two shares summing to the class counter, whichever class spends" do
      active_window

      3.times { ledger.reserve!(:actor, now: frozen_time) }
      2.times { ledger.reserve!(:repository, now: frozen_time) }

      expect(budget.actor_share_used + budget.repository_share_used).to eq(budget.enrichment_used)
    end
  end

  describe "optimistic locking" do
    # The raw debit bumps lock_version by hand, so a stale in-memory record cannot
    # clobber the counters through an ordinary save.
    it "still raises on a stale Active Record write after a raw debit" do
      active_window
      stale = GithubApiBudget.sole

      ledger.reserve!(:poll, now: frozen_time)

      expect { stale.update!(poll_used: 99) }.to raise_error(ActiveRecord::StaleObjectError)
    end
  end
end
