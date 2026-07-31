require "rails_helper"

# The stress half of Extension D item 7: the ledger's guarantees under genuine contention,
# from several PostgreSQL sessions at once.
#
# Everything here is provable in principle from budget_ledger_spec.rb's single-threaded
# examples plus the `SELECT … FOR UPDATE` in the code — and that is exactly why these exist.
# The single-threaded examples pass just as happily if the row lock is removed. These do
# not. Github::RequestGate serialises outbound requests in production, so it would hide a
# broken ledger too; it is deliberately absent here, because the ledger's correctness must
# not depend on it.
#
# Transactional tests are off, for the reason spec/support/concurrency_helpers.rb gives:
# with them on the pool is pinned and every thread shares one session, so the debits would
# serialise for the wrong reason and the examples would prove nothing. That costs explicit
# cleanup, done in around/ensure so it runs even when an example raises — a committed row 1
# surviving into another example would break every create_budget in the suite.
#
# It also costs a separate process, which is why this file lives under spec/stress and not
# beside the ledger's other specs. spec/stress/README.md explains it: opening genuine extra
# sessions changes the shared pool for the *whole* run, and the rest of the suite is built
# on there being exactly one.
RSpec.describe Github::BudgetLedger, "under concurrency" do
  self.use_transactional_tests = false

  subject(:ledger) { described_class.new }

  let(:now) { Time.current }

  around do |example|
    example.run
  ensure
    ActiveRecord::Base.connection.execute("DELETE FROM github_api_budget")
    ActiveRecord::Base.connection.execute("DELETE FROM event_sources")
    restore_connection_pool!
  end

  # The same shape as spec/support/budget_helpers.rb's active window, committed rather than
  # rolled back, and with the counters an example wants to start from.
  def active_window(**overrides)
    ledger.bootstrap!(now: now)
    GithubApiBudget.where(id: GithubApiBudget::SINGLETON_ID).update_all({
      window_status: "active", window_initialized_at: now,
      limit: 60, remaining: 60, reset_at: now + 3600, observed_at: now,
      poll_allowance: 12, enrichment_allowance: 40, reserve: 0
    }.merge(overrides))
  end

  def budget = GithubApiBudget.uncached { GithubApiBudget.find(GithubApiBudget::SINGLETON_ID) }

  def reserve_all(count, request_class, borrow: false)
    reservation_outcomes(in_parallel(count) { ledger.reserve!(request_class, now: now, borrow: borrow) })
  end

  describe "the class allowance" do
    # The property the whole ledger exists for, and the one a lost update would break: at
    # most poll_allowance requests leave this application in a window, however many callers
    # ask at once.
    it "grants exactly the allowance and refuses the rest, whoever asks first" do
      active_window(poll_allowance: 8)

      outcomes = reserve_all(40, :poll)

      expect(outcomes[:unexpected]).to be_empty
      expect(outcomes).to include(granted: 8, denied: 32)
      expect(outcomes[:reasons]).to eq(class_allowance_exhausted: 32)
      expect(budget.poll_used).to eq(8)
    end

    it "records one debit per granted reservation, with no lost debits" do
      active_window(poll_allowance: 30)

      outcomes = reserve_all(30, :poll)

      expect(outcomes[:granted]).to eq(30)
      expect(budget.poll_used).to eq(30)
    end

    # §10: enrichment spending its forty attempts never stops polling, and polling spending
    # its twelve never stops enrichment. Under contention that is a statement about two
    # counters updated in the same transaction as each other's guard.
    it "keeps the two classes isolated while both are being spent" do
      active_window(poll_allowance: 4, enrichment_allowance: 40)

      results = in_parallel(24) do |index|
        index.even? ? ledger.reserve!(:poll, now: now) : ledger.reserve!(:actor, now: now, borrow: true)
      end
      polls, enrichments = results.partition.with_index { |_, index| index.even? }

      expect(reservation_outcomes(polls)).to include(granted: 4, denied: 8)
      expect(reservation_outcomes(enrichments)).to include(granted: 12, denied: 0)
    end
  end

  describe "the fairness shares" do
    it "holds each class to its guarantee when neither may borrow" do
      active_window(enrichment_allowance: 40)

      actors = reserve_all(30, :actor)

      expect(actors).to include(granted: 20, denied: 10)
      expect(actors[:reasons]).to eq(share_exhausted: 10)
      expect(budget).to have_attributes(actor_share_used: 20, enrichment_used: 20)
    end

    # The invariant §10's borrowing rests on: whichever classes spend and in whatever
    # interleaving, the two shares always add up to the class counter.
    it "keeps the shares summing to the class counter under mixed contention" do
      active_window(enrichment_allowance: 40)

      in_parallel(40) do |index|
        ledger.reserve!(index.even? ? :actor : :repository, now: now)
      end

      expect(budget.actor_share_used + budget.repository_share_used).to eq(budget.enrichment_used)
      expect(budget.actor_share_used).to be <= 20
      expect(budget.repository_share_used).to be <= 20
    end

    # A borrow lifts the share cap to the class cap and not one request further — the
    # single-threaded example asserts the arithmetic, this asserts that concurrent borrowers
    # cannot each pass a guard the other has already consumed.
    it "lets concurrent borrowers reach the class allowance and stop there" do
      active_window(enrichment_allowance: 25)

      outcomes = reserve_all(60, :repository, borrow: true)

      expect(outcomes[:unexpected]).to be_empty
      expect(outcomes).to include(granted: 25)
      expect(budget).to have_attributes(enrichment_used: 25, repository_share_used: 25)
    end
  end

  describe "the reserve" do
    # The only guard that reflects GitHub's remaining rather than our own counters, and the
    # one that has to hold when a co-tenant leaves a small number behind.
    it "stops every class at the reserve, however many callers are in flight" do
      active_window(remaining: 12, reserve: 8, poll_allowance: 40)

      outcomes = reserve_all(30, :poll)

      expect(outcomes).to include(granted: 4)
      expect(outcomes[:reasons]).to eq(reserve_reached: 26)
      expect(budget.remaining).to eq(8)
    end
  end

  describe "a window rolling under load" do
    # Rollover happens inside the same transaction as the debit that discovered it, so a
    # second caller arriving mid-roll must either wait for it or find it already done. The
    # failure this rules out is two rollovers — which would zero a counter that had already
    # been debited in the new window.
    it "performs one rollover before every reservation lands in the new window" do
      active_window(poll_allowance: 12, reset_at: now - 1, poll_used: 12)

      outcomes = reserve_all(12, :poll)

      expect(outcomes[:unexpected]).to be_empty
      expect(outcomes).to include(granted: 12, denied: 0)
      expect(budget).to have_attributes(poll_used: 12, window_status: "uninitialized", remaining: nil)
    end
  end

  describe "#bootstrap!" do
    # ON CONFLICT DO NOTHING under READ COMMITTED: a losing insert blocks on the winner's
    # uncommitted tuple and then does nothing. Correct with no retry, and the row is a
    # schema-level singleton, so a second one is not merely wrong but impossible.
    it "creates exactly one row from a cold start, whoever wins" do
      results = in_parallel(20) { ledger.bootstrap!(now: now) }

      expect(results.grep(StandardError)).to be_empty
      expect(GithubApiBudget.uncached { GithubApiBudget.count }).to eq(1)
    end

    it "leaves a cold start able to poll immediately after the race" do
      in_parallel(20) { ledger.bootstrap!(now: now) }

      expect { ledger.reserve!(:poll, now: now) }.not_to raise_error
    end
  end
end
