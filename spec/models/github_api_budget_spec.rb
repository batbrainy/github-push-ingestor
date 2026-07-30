require "rails_helper"

RSpec.describe GithubApiBudget do
  it "is stored in a singular table because it holds exactly one row" do
    expect(described_class.table_name).to eq("github_api_budget")
  end

  describe "the singleton constraint" do
    it "defaults the primary key to the singleton id" do
      expect(create_budget.id).to eq(described_class::SINGLETON_ID)
    end

    # Enforced in the schema rather than the application, so no process — poller,
    # worker, or one-shot — can create a second ledger to reserve against (§7).
    it "rejects a second row at the database level" do
      create_budget

      expect_violation(ActiveRecord::CheckViolation) do
        described_class.connection.execute(<<~SQL.squish)
          INSERT INTO github_api_budget (id, created_at, updated_at)
          VALUES (2, NOW(), NOW())
        SQL
      end

      expect(described_class.count).to eq(1)
    end
  end

  describe "window state" do
    it "starts uninitialized, so enrichment is ineligible until a poll bootstraps it" do
      budget = create_budget

      expect(budget.window_status).to eq("uninitialized")
      expect(budget.limit).to be_nil
      expect(budget.remaining).to be_nil
      expect(budget.reset_at).to be_nil
    end

    it "accepts every documented window status" do
      budget = create_budget

      described_class::WINDOW_STATUSES.each do |status|
        budget.update!(window_status: status)
        expect(budget.reload.window_status).to eq(status)
      end
    end

    it "rejects an undocumented window status at the database level" do
      budget = create_budget

      expect_violation(ActiveRecord::CheckViolation) do
        described_class.where(id: budget.id).update_all(window_status: "invented")
      end
    end
  end

  describe "class counters" do
    it "start at zero so a fresh window has nothing spent" do
      budget = create_budget

      described_class::COUNTERS.each do |counter|
        expect(budget.public_send(counter)).to eq(0), "expected #{counter} to default to 0"
      end
    end

    it "rejects a negative counter at the database level" do
      budget = create_budget

      described_class::COUNTERS.each do |counter|
        expect_violation(ActiveRecord::CheckViolation) do
          described_class.where(id: budget.id).update_all(counter => -1)
        end
      end
    end

    it "rejects a negative header value" do
      budget = create_budget

      %i[limit remaining].each do |column|
        expect_violation(ActiveRecord::CheckViolation) do
          described_class.where(id: budget.id).update_all(column => -1)
        end
      end
    end

    # Reservation arithmetic (used <= allowance, reserve headroom) is deliberately not
    # constrained here — PR 4's BudgetLedger owns it.
    it "permits usage above the current allowance, which the ledger reconciles" do
      budget = create_budget

      expect { budget.update!(poll_allowance: 12, poll_used: 20) }.not_to raise_error
    end
  end

  describe "optimistic locking" do
    it "refuses a stale write so concurrent reservations cannot be lost" do
      create_budget
      first = described_class.sole
      second = described_class.sole

      first.update!(poll_used: 1)

      expect { second.update!(poll_used: 2) }.to raise_error(ActiveRecord::StaleObjectError)
    end
  end

  describe "derived class blocking" do
    # Plan §10: one timestamp cannot serve both. Class blocking is derived from the
    # counters so that enrichment exhausting its allowance never stops polling.
    it "stores no per-class block timestamp" do
      expect(described_class.column_names.grep(/class_blocked/)).to be_empty
    end

    it "stores only the global block" do
      expect(described_class.column_names).to include("global_blocked_until")
    end

    # The derivation §10 specifies, computed from three columns of this row at read time —
    # so it cannot go stale across a window rollover the way a stored value would.
    describe "#poll_class_blocked_until" do
      it "is nil while the class still has allowance left" do
        budget = create_budget(poll_used: 11, poll_allowance: 12, reset_at: frozen_time + 3600)

        expect(budget.poll_class_blocked_until(now: frozen_time)).to be_nil
      end

      it "defers to the window reset once the allowance is spent" do
        budget = create_budget(poll_used: 12, poll_allowance: 12, reset_at: frozen_time + 3600)

        expect(budget.poll_class_blocked_until(now: frozen_time)).to eq(frozen_time + 3600)
      end

      # §7's per-window bootstrap depends on this: right after a rollover the counters are
      # zero and reset_at is NULL, so nothing defers and the first real poll of the window
      # is free to initialize it from authoritative headers.
      it "is nil on a window that has not been initialized, which is what lets the first poll bootstrap it" do
        budget = create_budget(poll_used: 0, poll_allowance: 12, reset_at: nil)

        expect(budget.poll_class_blocked_until(now: frozen_time)).to be_nil
      end

      # Allowances#clamped yields poll_allowance = 0 when the observed limit is at or below
      # the reserve. The plan's literal ternary would then return nil — "not blocked" — for
      # a class that provably cannot spend, and a poller would re-attempt every tick
      # forever. "Blocked, but we do not know until when" has to resolve to a bounded
      # instant.
      it "falls back to one cadence when the allowance is spent and no reset is known" do
        budget = create_budget(poll_used: 0, poll_allowance: 0, reset_at: nil)

        expect(budget.poll_class_blocked_until(now: frozen_time, cadence_seconds: 300))
          .to eq(frozen_time + 300)
      end

      # A dead window never over-defers: its reset is in the past, so the term is in the
      # past, and the ledger rolls the window on the next reservation.
      it "names an instant that has already passed rather than blocking indefinitely" do
        budget = create_budget(poll_used: 12, poll_allowance: 12, reset_at: frozen_time - 60)

        expect(budget.poll_class_blocked_until(now: frozen_time)).to be < frozen_time
      end
    end

    # The same derivation for the other class, and the reason there are two rather than one
    # shared timestamp: §10 requires enrichment spending its forty attempts never to stop
    # polling, and polling spending its twelve never to stop enrichment.
    describe "#enrichment_class_blocked_until" do
      it "is nil while the class still has allowance left" do
        budget = create_budget(enrichment_used: 39, enrichment_allowance: 40, reset_at: frozen_time + 3600)

        expect(budget.enrichment_class_blocked_until(now: frozen_time)).to be_nil
      end

      it "defers to the window reset once the allowance is spent" do
        budget = create_budget(enrichment_used: 40, enrichment_allowance: 40, reset_at: frozen_time + 3600)

        expect(budget.enrichment_class_blocked_until(now: frozen_time)).to eq(frozen_time + 3600)
      end

      it "is nil on a window that has not been initialized" do
        budget = create_budget(enrichment_used: 0, enrichment_allowance: 40, reset_at: nil)

        expect(budget.enrichment_class_blocked_until(now: frozen_time)).to be_nil
      end

      # One *poll* cadence, because of what the unknown actually is: reset_at is NULL
      # exactly when the window has not been initialized, and §7 says only a poll can
      # initialize it. "After the next poll could plausibly have happened" is the honest
      # instant.
      it "falls back to one poll cadence when the allowance is spent and no reset is known" do
        budget = create_budget(enrichment_used: 0, enrichment_allowance: 0, reset_at: nil)

        expect(budget.enrichment_class_blocked_until(now: frozen_time, cadence_seconds: 300))
          .to eq(frozen_time + 300)
      end

      # §9's third term names enrichment_used, not a share. A share exhaustion is a denial
      # and not a deferral: it is relieved either by the window rolling or by the other
      # class running out of eligible candidates, and the second has no instant to name.
      # Deferring on it would also make §10's borrowing unreachable — the schedule would
      # answer "not due" before the runner ever computed a borrow.
      it "ignores the per-class shares, because a share exhaustion is a denial and not a deferral" do
        budget = create_budget(enrichment_used: 20, enrichment_allowance: 40,
                               actor_share_used: 20, repository_share_used: 0,
                               reset_at: frozen_time + 3600)

        expect(budget.enrichment_class_blocked_until(now: frozen_time)).to be_nil
      end

      it "leaves polling unaffected when enrichment is the class that is spent" do
        budget = create_budget(enrichment_used: 40, enrichment_allowance: 40,
                               poll_used: 3, poll_allowance: 12, reset_at: frozen_time + 3600)

        expect(budget.poll_class_blocked_until(now: frozen_time)).to be_nil
        expect(budget.enrichment_class_blocked_until(now: frozen_time)).to eq(frozen_time + 3600)
      end
    end
  end
end
