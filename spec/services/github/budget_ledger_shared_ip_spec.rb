require "rails_helper"

# The unauthenticated limit is keyed to the outbound IP, so anything else behind that IP
# spends the same sixty requests an hour. §7 and ADR 0004 both state the consequence —
# "the ledger coordinates this application only... GitHub's response headers remain the
# source of truth, and the ledger converges to them" — and this file is the advanced half
# of Extension A item 1: what the ledger does when the headers and our own counters
# disagree because someone else is spending.
#
# Distinct from budget_ledger_spec.rb's reconciliation examples, which establish the
# monotonic rule itself. These are the co-tenant scenarios that rule exists for.
RSpec.describe Github::BudgetLedger, "shared-IP reconciliation" do
  subject(:ledger) { described_class.new }

  let(:window_reset) { frozen_time + 3600 }

  def budget = current_budget
  def active_window(**overrides) = active_budget_window(**overrides)

  def snapshot(reset_at: window_reset, observed_at: frozen_time, **overrides)
    Github::RateLimitSnapshot.from_headers({
      "x-ratelimit-resource" => "core", "x-ratelimit-limit" => "60",
      "x-ratelimit-remaining" => "59", "x-ratelimit-reset" => reset_at.to_i.to_s
    }.merge(overrides.transform_keys(&:to_s)), observed_at: observed_at)
  end

  describe "a co-tenant draining the window" do
    # The one denial that reflects GitHub's view rather than our own counters, and the
    # reason it exists: without it our class counters would happily grant requests into a
    # remaining of zero because *we* had not spent them.
    it "denies both classes on the observed remaining, whatever our counters say" do
      active_window(remaining: 59)
      ledger.reserve!(:poll, now: frozen_time)
      ledger.reconcile!(snapshot("x-ratelimit-remaining" => "6"), now: frozen_time)

      expect { ledger.reserve!(:poll, now: frozen_time) }
        .to raise_error(Github::Errors::BudgetExhausted) { |e| expect(e.reason).to eq(:reserve_reached) }
      expect { ledger.reserve!(:actor, now: frozen_time) }
        .to raise_error(Github::Errors::BudgetExhausted) { |e| expect(e.reason).to eq(:reserve_reached) }
    end

    # The important half: a co-tenant can stop this application for the rest of the window,
    # but not past it. Nothing else could recover the row — a reserve breach denies the very
    # poll that would observe a new remaining — so the clock has to, and it does.
    it "recovers at the window boundary, which is the only thing that can clear it" do
      active_window(remaining: 59)
      ledger.reserve!(:poll, now: frozen_time)
      ledger.reconcile!(snapshot("x-ratelimit-remaining" => "0"), now: frozen_time)

      expect { ledger.reserve!(:poll, now: window_reset + 1) }.not_to raise_error
      expect(budget).to have_attributes(window_status: "uninitialized", remaining: nil, poll_used: 1)
    end

    it "keeps enrichment ineligible in the recovered window until a poll re-initializes it" do
      active_window(remaining: 59)
      ledger.reconcile!(snapshot("x-ratelimit-remaining" => "0"), now: frozen_time)
      ledger.reserve!(:poll, now: window_reset + 1)

      expect { ledger.reserve!(:actor, now: window_reset + 1) }
        .to raise_error(Github::Errors::BudgetExhausted) { |e| expect(e.reason).to eq(:window_uninitialized) }
    end

    # §7: "another application behind the same IP may have consumed budget immediately
    # after the reset — never assume 60 remaining". The bootstrap poll is what discovers it.
    it "opens a window on a co-tenant's leftovers rather than on the documented sixty" do
      ledger.bootstrap!(now: frozen_time)
      ledger.reserve!(:poll, now: frozen_time)

      ledger.reconcile!(snapshot("x-ratelimit-remaining" => "9", "x-ratelimit-used" => "51"),
                        now: frozen_time)

      expect(budget).to have_attributes(window_status: "active", remaining: 9)
    end
  end

  describe "an observed limit that changes mid-window" do
    # ADR 0004: "allowances are re-derived at window rollover and initialization, not
    # mid-window... the price of keeping the change atomic with the counter reset."
    # A limit of 22 cannot fund the 12 + 4 + 8 this window stores — the helper's
    # deliberately small detail allowance, not the 40 a real window derives — so a
    # re-derivation here would have clamped the detail allowance to 2, which is how
    # staying at 4 proves nothing was re-derived.
    it "stores the new limit without re-deriving the allowances under it" do
      active_window
      ledger.reconcile!(snapshot("x-ratelimit-limit" => "22", "x-ratelimit-remaining" => "20"),
                        now: frozen_time)

      expect(budget).to have_attributes(limit: 22, poll_allowance: 12, enrichment_allowance: 4)
    end

    it "derives from the new limit at the next rollover, clamping the detail allowance to what it funds" do
      active_window
      ledger.reconcile!(snapshot("x-ratelimit-limit" => "22", "x-ratelimit-remaining" => "20"),
                        now: frozen_time)

      ledger.reserve!(:poll, now: window_reset + 1)

      expect(budget).to have_attributes(poll_allowance: 12, enrichment_allowance: 2)
    end

    # The gap in between is real and is what the reserve guard covers: the row's own
    # counters would still authorise sixteen attempts, and `remaining <= reserve` is what
    # actually stops them against the drained window GitHub reports.
    it "leaves the reserve guard, not the allowances, holding the line until then" do
      active_window
      ledger.reconcile!(snapshot("x-ratelimit-limit" => "30", "x-ratelimit-remaining" => "8"),
                        now: frozen_time)

      expect { ledger.reserve!(:actor, now: frozen_time) }
        .to raise_error(Github::Errors::BudgetExhausted) { |e| expect(e.reason).to eq(:reserve_reached) }
    end

    it "adopts a raised limit too, since headers are authoritative in both directions" do
      active_window
      ledger.reconcile!(snapshot("x-ratelimit-limit" => "5000", "x-ratelimit-remaining" => "4999"),
                        now: frozen_time)

      # remaining still only moves down within the window: the monotonic rule is about
      # protecting a conservative local estimate, and it is indifferent to the limit.
      expect(budget).to have_attributes(limit: 5000, remaining: 55)
    end
  end

  describe "usage this application did not make" do
    before { allow(Rails.logger).to receive(:debug) }

    it "reports the divergence between GitHub's count and our own" do
      active_window(poll_used: 2, enrichment_used: 3)

      ledger.reconcile!(snapshot("x-ratelimit-used" => "20", "x-ratelimit-remaining" => "40"),
                        now: frozen_time)

      expect(Rails.logger).to have_received(:debug).with(
        hash_including(event: "budget.co_tenant_usage", phase: "updated",
                       observed_used: 20, ledger_used: 5, divergence: 15)
      )
    end

    # The window opened on someone else's spending, which is exactly what §7's per-window
    # bootstrap exists to discover.
    it "reports it at window initialization too, so the opening balance is visible" do
      ledger.bootstrap!(now: frozen_time)
      ledger.reserve!(:poll, now: frozen_time)

      ledger.reconcile!(snapshot("x-ratelimit-used" => "31", "x-ratelimit-remaining" => "29"),
                        now: frozen_time)

      expect(Rails.logger).to have_received(:debug).with(
        hash_including(event: "budget.co_tenant_usage", phase: "initialized",
                       observed_used: 31, ledger_used: 1, divergence: 30)
      )
    end

    # DEBUG for the recurring observation, INFO for the transition that matters: the shared
    # IP has taken remaining to the reserve, so the next reservation of every class is about
    # to be denied and the silence needs a cause attached to it.
    it "raises the line to INFO once the co-tenant has taken remaining to the reserve" do
      allow(Rails.logger).to receive(:info)
      active_window(poll_used: 1)

      ledger.reconcile!(snapshot("x-ratelimit-used" => "50", "x-ratelimit-remaining" => "8"),
                        now: frozen_time)

      expect(Rails.logger).to have_received(:info).with(
        hash_including(event: "budget.co_tenant_pressure", divergence: 49,
                       observed_remaining: 8, reserve: 8)
      )
      expect(Rails.logger).not_to have_received(:debug)
        .with(hash_including(event: "budget.co_tenant_usage"))
    end

    it "says nothing when GitHub's count matches our own" do
      active_window(poll_used: 4)

      ledger.reconcile!(snapshot("x-ratelimit-used" => "4", "x-ratelimit-remaining" => "56"),
                        now: frozen_time)

      expect(Rails.logger).not_to have_received(:debug)
        .with(hash_including(event: "budget.co_tenant_usage"))
    end

    it "says nothing when the response carried no used header to compare against" do
      active_window(poll_used: 4)

      ledger.reconcile!(snapshot, now: frozen_time)

      expect(Rails.logger).not_to have_received(:debug)
        .with(hash_including(event: "budget.co_tenant_usage"))
    end

    # Reported, never applied. GitHub's used carries no request class, so adopting it would
    # have to guess one — and a guess breaks the invariant that the two shares sum to
    # enrichment_used, which is what the fairness split is enforced against.
    it "never corrects our class counters from a number it cannot attribute" do
      active_window(poll_used: 2, enrichment_used: 3, actor_share_used: 2, repository_share_used: 1)

      ledger.reconcile!(snapshot("x-ratelimit-used" => "40", "x-ratelimit-remaining" => "20"),
                        now: frozen_time)

      expect(budget).to have_attributes(poll_used: 2, enrichment_used: 3,
                                        actor_share_used: 2, repository_share_used: 1)
    end
  end

  describe "a window that rolls while a co-tenant holds it down" do
    # The low reading belonged to the window that just ended. Carrying it into the new one
    # would deny every request in a window that may be completely free — and rollover nulls
    # remaining precisely so the next response, not the last one, decides.
    it "does not carry the drained remaining into the window that supersedes it" do
      active_window(remaining: 9)
      ledger.reserve!(:poll, now: frozen_time)

      ledger.reconcile!(snapshot(reset_at: window_reset + 3600, "x-ratelimit-remaining" => "58"),
                        request_class: :poll, now: frozen_time)

      expect(budget).to have_attributes(window_status: "active", remaining: 58, poll_used: 1)
    end

    it "carries the in-flight debit into the window GitHub counted it in" do
      active_window(poll_used: 5)
      ledger.reserve!(:actor, now: frozen_time)

      ledger.reconcile!(snapshot(reset_at: window_reset + 3600), request_class: :actor,
                        now: frozen_time)

      expect(budget).to have_attributes(poll_used: 0, enrichment_used: 1, actor_share_used: 1)
    end
  end

  describe "the global block a reserve breach produces (plan §10)" do
    subject(:policy) { Github::RateLimitPolicy.new(ledger: ledger) }

    def denied
      Github::FetchResult.from_error(
        request: Github::Request.new(url: "https://api.github.com/events", request_class: :poll),
        error: Github::Errors::BudgetExhausted.new(:poll, :reserve_reached),
        attempt: 0, classification: :budget_denied
      )
    end

    it "stops every live request until the window resets" do
      active_window(remaining: 8)

      decision = policy.apply!(denied, now: frozen_time)

      expect(decision).to have_attributes(kind: :reserve_reached, blocked_until: window_reset)
      expect(budget.global_blocked_until).to eq(window_reset)
    end

    # A reserve breach always implies an initialized window — remaining is NULL until one is
    # opened — so the only way to reach a nil reset_at here is a rollover landing between the
    # denial and this read. Blocking on a window that no longer exists would be worse than
    # not blocking: the next reservation is against fresh counters and is legitimate.
    it "declines to block when a rollover has already retired the window it would name" do
      active_window(remaining: 8)
      ledger.reserve!(:poll, now: window_reset + 1)

      decision = policy.apply!(denied, now: window_reset + 1)

      expect(decision.kind).to eq(:none)
      expect(budget.global_blocked_until).to be_nil
    end
  end
end
