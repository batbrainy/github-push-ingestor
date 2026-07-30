require "rails_helper"

# §12 asks for a unit test of "effective_poll_time (components independent;
# global_blocked_until only for global conditions; --force bypasses cadence + ETag only)".
# It is only a unit test if it needs no database, which is why PollSchedule is a value
# object over five Times rather than a method on either model it reads.
RSpec.describe Github::PollSchedule do
  let(:now) { frozen_time }

  def schedule(**components)
    described_class.new(**described_class::COMPONENTS.index_with { nil }.merge(components))
  end

  describe "#effective_poll_time" do
    # nil is the ordinary case, not an edge one: every column is nil on a clean checkout,
    # so a caller that compared `now < effective_poll_time` would crash on the very first
    # poll a reviewer runs.
    it "is nil when nothing constrains the poll, which is a clean checkout's state" do
      expect(schedule.effective_poll_time).to be_nil
      expect(schedule.due?(now: now)).to be(true)
    end

    it "takes the latest constraint, so any one of the five can hold the poll back" do
      described_class::COMPONENTS.each do |component|
        one = schedule(component => now + 600)

        expect(one.effective_poll_time).to eq(now + 600)
        expect(one.due?(now: now)).to be(false)
        expect(one.binding_component).to eq(component)
      end
    end

    it "ignores the components that are not set rather than treating them as now" do
      expect(schedule(poll_floor_until: now + 60, retry_not_before_at: now + 900).effective_poll_time)
        .to eq(now + 900)
    end

    it "is due at exactly the instant it names" do
      # <= rather than <: PostgreSQL truncates a timestamp to microseconds on the way in
      # and Time.current does not, so a round-tripped instant can compare unequal to the
      # one that produced it.
      expect(schedule(cadence_due_at: now).due?(now: now)).to be(true)
    end

    it "is due again once every constraint has passed" do
      past = schedule(cadence_due_at: now - 1, global_blocked_until: now - 300)

      expect(past.due?(now: now)).to be(true)
    end
  end

  # §9: "--force bypasses the application's configured cadence (cadence_due_at) and omits
  # the stored ETag — nothing else. It does not bypass the source lock, poll_floor_until,
  # retry_not_before_at, global_blocked_until, class blocking, or the reserve policy."
  #
  # The four examples below are that sentence, one clause at a time. The source lock is
  # outside this object entirely — IngestionRunner acquires it before force is read — and
  # the reserve is BudgetLedger's, which knows nothing about force at all.
  describe "--force" do
    it "drops the configured cadence" do
      forced = schedule(cadence_due_at: now + 300)

      expect(forced.due?(now: now, force: true)).to be(true)
      expect(forced.effective_poll_time(force: true)).to be_nil
    end

    it "still obeys GitHub's own poll floor" do
      forced = schedule(cadence_due_at: now + 300, poll_floor_until: now + 60)

      expect(forced.due?(now: now, force: true)).to be(false)
      expect(forced.binding_component(force: true)).to eq(:poll_floor_until)
    end

    it "still obeys this source's backoff" do
      forced = schedule(cadence_due_at: now + 300, retry_not_before_at: now + 120)

      expect(forced.due?(now: now, force: true)).to be(false)
      expect(forced.binding_component(force: true)).to eq(:retry_not_before_at)
    end

    it "still obeys a global block" do
      forced = schedule(cadence_due_at: now + 300, global_blocked_until: now + 1800)

      expect(forced.due?(now: now, force: true)).to be(false)
      expect(forced.binding_component(force: true)).to eq(:global_blocked_until)
    end

    it "still obeys class blocking, so a forced run cannot spend an allowance that is gone" do
      forced = schedule(cadence_due_at: now + 300, poll_class_blocked_until: now + 3600)

      expect(forced.due?(now: now, force: true)).to be(false)
      expect(forced.binding_component(force: true)).to eq(:poll_class_blocked_until)
    end

    it "drops the cadence from the reported components, and nothing else" do
      full = schedule(**described_class::COMPONENTS.index_with { now + 60 })

      expect(full.components(force: true).keys)
        .to match_array(described_class::COMPONENTS - described_class::FORCEABLE)
    end
  end

  describe "#binding_component" do
    it "names the constraint that produced the answer, so an operator knows which of five to change" do
      expect(schedule(cadence_due_at: now + 60, global_blocked_until: now + 3600).binding_component)
        .to eq(:global_blocked_until)
    end

    it "breaks a tie in the plan's order, which is the most actionable constraint first" do
      tied = schedule(cadence_due_at: now + 60, poll_floor_until: now + 60)

      expect(tied.binding_component).to eq(:cadence_due_at)
    end

    it "is nil when nothing constrains the poll" do
      expect(schedule.binding_component).to be_nil
    end
  end

  describe ".for" do
    let(:event_source) { create_event_source(cadence_due_at: now + 300, poll_floor_until: now + 60) }

    it "reads the three source components and the two ledger ones" do
      budget = create_budget(global_blocked_until: now + 900, poll_used: 12, poll_allowance: 12,
                             reset_at: now + 3600, window_status: "active")

      built = described_class.for(event_source: event_source, budget: budget, now: now)

      expect(built).to have_attributes(
        cadence_due_at: now + 300, poll_floor_until: now + 60, retry_not_before_at: nil,
        global_blocked_until: now + 900, poll_class_blocked_until: now + 3600
      )
    end

    # Nothing seeds the ledger row: only a reservation creates it. A missing one constrains
    # nothing, which is exactly what lets the first poll of a fresh install happen and
    # bootstrap the window (§7).
    it "treats a missing ledger row as no constraint rather than as a block" do
      built = described_class.for(event_source: event_source, budget: nil, now: now)

      expect(built.global_blocked_until).to be_nil
      expect(built.poll_class_blocked_until).to be_nil
    end

    it "does not create the ledger row it reads" do
      expect { described_class.for(event_source: event_source, now: now) }
        .not_to change(GithubApiBudget, :count).from(0)
    end

    # §7 calls next_poll_at an "optional cached effective value". Caching the answer is
    # fine; reading it back is not — it goes stale the moment a block clears, and
    # consulting it would re-introduce the single collapsed timestamp §9 exists to avoid.
    it "never reads next_poll_at, so a stale cache cannot defer a source that is due" do
      event_source.update!(cadence_due_at: nil, poll_floor_until: nil, next_poll_at: now + 1.day)

      expect(described_class.for(event_source: event_source, now: now).due?(now: now)).to be(true)
    end
  end

  describe "#to_log" do
    it "renders only the components in play, as UTC instants" do
      expect(schedule(cadence_due_at: now + 300).to_log).to eq(cadence_due_at: (now + 300).utc.iso8601)
    end
  end
end
