require "rails_helper"

RSpec.describe Github::PollBackoff do
  # Injected rather than stubbed, the same way RetryPolicy's spec does it: the schedule is
  # asserted exactly, and nothing sleeps.
  let(:no_jitter) { described_class.new(random: instance_double(Random, rand: 0.0)) }
  let(:full_jitter) { described_class.new(random: instance_double(Random, rand: 1.0)) }

  describe "#delay_for" do
    it "starts at the observed X-Poll-Interval floor, so a failed source is never retried faster than a healthy one" do
      expect(no_jitter.delay_for(1)).to eq(60.0)
    end

    it "doubles with each consecutive failure" do
      expect([ 1, 2, 3, 4 ].map { |n| no_jitter.delay_for(n) }).to eq([ 60.0, 120.0, 240.0, 480.0 ])
    end

    # A dead source is still retried hourly rather than deferred into next week: past one
    # rate-limit window, waiting longer buys nothing, because the budget has refreshed and
    # the next attempt costs one of a fresh sixty.
    it "caps at one rate-limit window" do
      expect(no_jitter.delay_for(20)).to eq(described_class::MAX_SECONDS.to_f)
    end

    it "caps after jitter, so MAX_SECONDS is an honest bound rather than a bound plus a quarter" do
      expect(full_jitter.delay_for(20)).to eq(described_class::MAX_SECONDS.to_f)
    end

    # Additive only. Subtracting could schedule a retry sooner than §10's stated "≥ 1
    # minute", which is the one number in this file the plan fixes.
    it "only ever lengthens a delay with jitter" do
      expect(full_jitter.delay_for(1)).to eq(75.0)
      expect(full_jitter.delay_for(1)).to be > no_jitter.delay_for(1)
    end

    it "treats a zeroth failure as the first, so the floor is never halved" do
      expect(no_jitter.delay_for(0)).to eq(60.0)
    end
  end

  describe "#retry_at" do
    it "offsets from the instant it is given rather than from the wall clock" do
      now = Time.utc(2026, 7, 30, 12, 0, 0)

      expect(no_jitter.retry_at(2, now: now)).to eq(now + 120)
    end
  end
end
