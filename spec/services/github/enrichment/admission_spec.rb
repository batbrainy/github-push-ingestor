require "rails_helper"

# Read-side admission for the two enrichment lanes. Advisory only: the ledgers re-check
# everything under their row locks, so what these examples pin down is the churn
# contract — a denied tick enqueues no cycle, names its reason, and says when to ask
# again — plus the read-only discipline that a pre-check must never create ledger rows.
RSpec.describe Github::Enrichment::Admission do
  subject(:admission) { described_class.new }

  describe "#search" do
    # The search ledger self-bootstraps from configuration, unlike core — so a missing
    # row means "nothing has ever been denied", not "nothing is known".
    it "grants when no search ledger row exists, and creates none" do
      verdict = admission.search(now: frozen_time)

      expect(verdict).to be_granted
      expect(verdict).to have_attributes(reason: nil, retry_in_seconds: nil)
      expect(GithubSearchBudget.count).to eq(0)
    end

    it "grants against a fresh mid-window row" do
      active_search_window

      expect(admission.search(now: frozen_time)).to be_granted
    end

    it "denies :search_blocked with the seconds until the block lifts" do
      active_search_window(blocked_until: frozen_time + 30)

      expect(admission.search(now: frozen_time))
        .to have_attributes(reason: :search_blocked, retry_in_seconds: 30.0)
    end

    it "denies :search_pacing with the seconds until the pacing interval elapses" do
      active_search_window(last_request_at: frozen_time - 2)

      expect(admission.search(now: frozen_time))
        .to have_attributes(reason: :search_pacing, retry_in_seconds: 4.0)
    end

    it "denies :search_reserve_reached until the reset GitHub named" do
      active_search_window(remaining: 2)

      expect(admission.search(now: frozen_time))
        .to have_attributes(reason: :search_reserve_reached, retry_in_seconds: 60.0)
    end

    # No reset was ever observed, so there is no instant to name — nil is "ask the
    # ledger again later", not "ask in zero seconds".
    it "denies :search_reserve_reached with no instant when no reset is known" do
      active_search_window(remaining: 2, reset_at: nil)

      expect(admission.search(now: frozen_time))
        .to have_attributes(reason: :search_reserve_reached, retry_in_seconds: nil)
    end

    it "denies :search_ceiling_exhausted until the reset" do
      active_search_window(remaining: nil, used: 8)

      expect(admission.search(now: frozen_time))
        .to have_attributes(reason: :search_ceiling_exhausted, retry_in_seconds: 60.0)
    end

    it "denies :search_ceiling_exhausted with no instant when no reset is known" do
      active_search_window(remaining: nil, used: 8, reset_at: nil)

      expect(admission.search(now: frozen_time))
        .to have_attributes(reason: :search_ceiling_exhausted, retry_in_seconds: nil)
    end

    # Counters from an elapsed window are stale: the ledger will roll them on its next
    # reservation, so a pre-check denying on them would withhold a grantable cycle.
    it "grants over spent counters once GitHub's reset instant has passed" do
      active_search_window(remaining: 2, used: 8, reset_at: frozen_time - 1)

      expect(admission.search(now: frozen_time)).to be_granted
    end

    it "grants over a header-less window once a full search window has passed in silence" do
      active_search_window(remaining: nil, used: 8, reset_at: nil,
                           last_request_at: frozen_time - 61)

      expect(admission.search(now: frozen_time)).to be_granted
    end

    # Pacing outranks window staleness deliberately, mirroring the ledger: the roll
    # resets counters, never the wire-spacing contract.
    it "still paces even when the window behind the counters has elapsed" do
      active_search_window(used: 8, reset_at: frozen_time - 1,
                           last_request_at: frozen_time - 2)

      expect(admission.search(now: frozen_time)).to have_attributes(reason: :search_pacing)
    end
  end

  describe "#detail" do
    # The detail lane keeps the core ledger's bootstrap discipline: no initialized
    # window, no enrichment (§7) — and a read path must never create the row.
    it "denies :window_uninitialized when no core ledger row exists, and creates none" do
      verdict = admission.detail(now: frozen_time)

      expect(verdict).to have_attributes(reason: :window_uninitialized, retry_in_seconds: nil)
      expect(GithubApiBudget.count).to eq(0)
    end

    it "denies :window_uninitialized while the row exists but no response opened it" do
      active_budget_window(window_status: "uninitialized", window_initialized_at: nil)

      expect(admission.detail(now: frozen_time))
        .to have_attributes(reason: :window_uninitialized)
    end

    # A dead window's counters prove nothing about the current hour; the ledger rolls
    # them on its next reservation, and until then the honest answer is "elapsed".
    it "denies :window_elapsed once the stored reset has passed" do
      active_budget_window(reset_at: frozen_time - 1)

      expect(admission.detail(now: frozen_time))
        .to have_attributes(reason: :window_elapsed, retry_in_seconds: nil)
    end

    it "denies :globally_blocked with the seconds until the block lifts" do
      active_budget_window(global_blocked_until: frozen_time + 120)

      expect(admission.detail(now: frozen_time))
        .to have_attributes(reason: :globally_blocked, retry_in_seconds: 120.0)
    end

    it "grants again once the global block has passed" do
      active_budget_window(global_blocked_until: frozen_time - 1)

      expect(admission.detail(now: frozen_time)).to be_granted
    end

    # enrichment_allowance now means CORE_DETAIL_FALLBACK_ALLOWANCE (=4), and the class
    # block is derived from the counters — spent allowance defers to the window reset.
    it "denies :class_exhausted once the detail-fallback allowance is spent" do
      active_budget_window(enrichment_used: 4)

      expect(admission.detail(now: frozen_time))
        .to have_attributes(reason: :class_exhausted, retry_in_seconds: 3600.0)
    end

    it "grants while the detail-fallback allowance has attempts left" do
      active_budget_window(enrichment_used: 3)

      expect(admission.detail(now: frozen_time)).to be_granted
    end
  end
end
