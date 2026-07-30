require "rails_helper"

RSpec.describe Github::BudgetLedger do
  subject(:ledger) { described_class.new }

  let(:window_reset) { frozen_time + 3600 }

  def budget
    GithubApiBudget.find(GithubApiBudget::SINGLETON_ID)
  end

  # A window already initialized from headers, which is where most reservations happen.
  def active_window(**overrides)
    ledger.bootstrap!(now: frozen_time)
    GithubApiBudget.where(id: GithubApiBudget::SINGLETON_ID).update_all({
      window_status: "active", window_initialized_at: frozen_time,
      limit: 60, remaining: 55, reset_at: window_reset, observed_at: frozen_time,
      poll_allowance: 12, enrichment_allowance: 40, reserve: 8
    }.merge(overrides))
    budget
  end

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

    # PR 7 adds the fairness guarantees on top of these counters. PR 4 only has to
    # record them accurately, so PR 7 has no back-fill problem.
    it "records the shares without enforcing a split between them, which is PR 7's" do
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

    # PR 4 enforces this column; PR 6 decides when to set it. Reading a column this PR
    # never writes costs one clause and means PR 6 does not have to reopen the ledger's
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
                            :class_allowance_exhausted)
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

  describe "failures stay spent (plan §7)" do
    # The guarantee is structural: there is no code path that gives a request back.
    it "exposes no way to credit a reservation back" do
      expect(described_class.instance_methods(false)).to contain_exactly(
        :reserve!, :reconcile!, :bootstrap!, :configuration
      )
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
