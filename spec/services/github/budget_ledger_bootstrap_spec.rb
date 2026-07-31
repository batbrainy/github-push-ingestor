require "rails_helper"

# §7's per-window bootstrap — "the first real poll, not an extra request" — under the
# conditions that are not the happy path. budget_ledger_spec.rb establishes that the
# bootstrap works; this file is about what happens when the response that was supposed to
# open the window cannot.
#
# The property every example here defends is the same one: the bootstrap must stay
# retryable. An uninitialized window grants polls, so a failed bootstrap costs one attempt
# and the next poll tries again — and nothing may ever reach a state where the only request
# able to open the window is the one being refused.
RSpec.describe Github::BudgetLedger, "bootstrap edge cases" do
  subject(:ledger) { described_class.new }

  let(:window_reset) { frozen_time + 3600 }

  def budget = current_budget

  def snapshot(reset_at: window_reset, observed_at: frozen_time, **overrides)
    Github::RateLimitSnapshot.from_headers({
      "x-ratelimit-resource" => "core", "x-ratelimit-limit" => "60",
      "x-ratelimit-remaining" => "59", "x-ratelimit-reset" => reset_at.to_i.to_s
    }.merge(overrides.transform_keys(&:to_s)), observed_at: observed_at)
  end

  def bootstrap_poll!
    ledger.bootstrap!(now: frozen_time)
    ledger.reserve!(:poll, now: frozen_time)
  end

  describe "a bootstrap response that carries nothing to open the window with" do
    # A 403 from an edge proxy, a 500 HTML error page, a truncated header set. The request
    # happened and is spent; there is simply nothing authoritative in it.
    it "leaves the window uninitialized when the rate-limit headers are incomplete" do
      bootstrap_poll!

      outcome = ledger.reconcile!(snapshot("x-ratelimit-limit" => nil, "x-ratelimit-remaining" => nil),
                                  request_class: :poll, now: frozen_time)

      expect(outcome).to eq(:partial_headers)
      expect(budget).to have_attributes(window_status: "uninitialized", window_initialized_at: nil,
                                        limit: nil, remaining: nil, reset_at: nil)
    end

    it "leaves it uninitialized when the transport produced no response at all" do
      bootstrap_poll!

      expect(ledger.reconcile!(nil, request_class: :poll, now: frozen_time)).to eq(:no_headers)
      expect(budget).to have_attributes(window_status: "uninitialized", window_initialized_at: nil)
    end

    # Failures stay spent (§7). The attempt reached GitHub whatever came back, and the
    # ledger's whole posture is that it is never given back.
    it "keeps the failed bootstrap attempt spent" do
      bootstrap_poll!
      ledger.reconcile!(nil, request_class: :poll, now: frozen_time)

      expect(budget.poll_used).to eq(1)
    end

    it "still refuses enrichment, which is what an uninitialized window means" do
      bootstrap_poll!
      ledger.reconcile!(nil, request_class: :poll, now: frozen_time)

      expect { ledger.reserve!(:actor, now: frozen_time) }
        .to raise_error(Github::Errors::BudgetExhausted) { |e| expect(e.reason).to eq(:window_uninitialized) }
    end

    # The retry is the point: an uninitialized window grants polls, so the class allowance
    # is what bounds the number of attempts a broken hour costs, not a special case.
    it "lets the next poll try the bootstrap again, and open the window when it works" do
      bootstrap_poll!
      ledger.reconcile!(nil, request_class: :poll, now: frozen_time)

      ledger.reserve!(:poll, now: frozen_time)
      ledger.reconcile!(snapshot, request_class: :poll, now: frozen_time)

      expect(budget).to have_attributes(window_status: "active", poll_used: 2, remaining: 59)
    end

    it "stops retrying when the poll allowance is spent, without any special casing" do
      ledger.bootstrap!(now: frozen_time)
      12.times do
        ledger.reserve!(:poll, now: frozen_time)
        ledger.reconcile!(nil, request_class: :poll, now: frozen_time)
      end

      expect { ledger.reserve!(:poll, now: frozen_time) }
        .to raise_error(Github::Errors::BudgetExhausted) { |e| expect(e.reason).to eq(:class_allowance_exhausted) }
    end
  end

  describe "a window that opens with nothing left in it" do
    # A co-tenant spent the hour the instant it reset. The window is genuinely active and
    # genuinely unusable, and the distinction matters: this is :reserve_reached, an
    # observation about GitHub's remaining, not :window_uninitialized.
    it "opens, then denies every class on the reserve" do
      bootstrap_poll!
      ledger.reconcile!(snapshot("x-ratelimit-remaining" => "8", "x-ratelimit-used" => "52"),
                        request_class: :poll, now: frozen_time)

      expect(budget.window_status).to eq("active")
      expect { ledger.reserve!(:poll, now: frozen_time) }
        .to raise_error(Github::Errors::BudgetExhausted) { |e| expect(e.reason).to eq(:reserve_reached) }
    end

    it "recovers at the boundary, because a denied poll can never observe a new remaining" do
      bootstrap_poll!
      ledger.reconcile!(snapshot("x-ratelimit-remaining" => "8"), request_class: :poll, now: frozen_time)

      expect { ledger.reserve!(:poll, now: window_reset + 1) }.not_to raise_error
    end
  end

  describe "a reset instant that has already passed" do
    let(:skewed) { snapshot(reset_at: frozen_time - 120) }

    # GitHub sends x-ratelimit-reset as an instant in the future, so a past one means this
    # container's clock runs ahead of GitHub's.
    it "opens the window anyway, because discarding the only observation helps nobody" do
      bootstrap_poll!

      expect(ledger.reconcile!(skewed, request_class: :poll, now: frozen_time)).to eq(:initialized)
      expect(budget.window_status).to eq("active")
    end

    it "names the skew, which is otherwise invisible" do
      allow(Rails.logger).to receive(:warn)
      bootstrap_poll!

      ledger.reconcile!(skewed, request_class: :poll, now: frozen_time)

      expect(Rails.logger).to have_received(:warn)
        .with(hash_including(event: "budget.window_reset_in_past", skew_seconds: 120))
    end

    # The consequence the warning exists for: the next reservation sees an elapsed window,
    # rolls it straight back to uninitialized, and enrichment — ineligible until a window is
    # initialized — never gets a single request for as long as the skew lasts. Polling is
    # unaffected, which is why this degrades rather than stops.
    it "rolls straight back to uninitialized on the next reservation, and still polls" do
      bootstrap_poll!
      ledger.reconcile!(skewed, request_class: :poll, now: frozen_time)

      expect { ledger.reserve!(:poll, now: frozen_time) }.not_to raise_error
      expect(budget.window_status).to eq("uninitialized")
    end

    it "says nothing about skew for a reset instant in the future" do
      allow(Rails.logger).to receive(:warn)
      bootstrap_poll!

      ledger.reconcile!(snapshot, request_class: :poll, now: frozen_time)

      expect(Rails.logger).not_to have_received(:warn)
        .with(hash_including(event: "budget.window_reset_in_past"))
    end
  end

  describe "a row that already exists" do
    # ON CONFLICT DO NOTHING is what makes a second bootstrap a no-op rather than a
    # RecordNotUnique — but it also means the row keeps allowances derived under whatever
    # configuration created it. ADR 0004 accepts that: allowances change at window
    # boundaries, "the price of keeping the change atomic with the counter reset".
    it "does not restate the allowances of a row another configuration created" do
      described_class.new(configuration: configuration_with(POLL_INTERVAL_SECONDS: "600"))
        .bootstrap!(now: frozen_time)

      ledger.bootstrap!(now: frozen_time)

      expect(budget).to have_attributes(poll_allowance: 6, enrichment_allowance: 46)
    end

    it "adopts the current configuration at the first window it opens" do
      described_class.new(configuration: configuration_with(POLL_INTERVAL_SECONDS: "600"))
        .bootstrap!(now: frozen_time)
      ledger.reserve!(:poll, now: frozen_time)

      ledger.reconcile!(snapshot, request_class: :poll, now: frozen_time)

      expect(budget).to have_attributes(poll_allowance: 12, enrichment_allowance: 40)
    end

    # A block set before the window was ever initialized. denial_reason derives blocking
    # from the timestamp alone precisely so no label can strand the row.
    it "keeps a global block that predates the window it never opened" do
      ledger.bootstrap!(now: frozen_time)
      ledger.block_globally!(until_at: frozen_time + 600, reason: :secondary_rate_limit, now: frozen_time)

      expect { ledger.reserve!(:poll, now: frozen_time) }
        .to raise_error(Github::Errors::BudgetExhausted) { |e| expect(e.reason).to eq(:globally_blocked) }
      expect(budget.window_status).to eq("uninitialized")
    end
  end
end
