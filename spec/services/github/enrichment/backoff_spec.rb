require "rails_helper"

RSpec.describe Github::Enrichment::Backoff do
  # Injected rather than stubbed, so the schedule is asserted without sleeping and without
  # reaching into Kernel — the technique Github::PollBackoff's own spec uses.
  subject(:backoff) { described_class.new(random: Random.new(1234)) }

  let(:no_jitter) { described_class.new(random: instance_double(Random, rand: 0.0)) }
  let(:full_jitter) { described_class.new(random: instance_double(Random, rand: 1.0)) }

  describe "#delay_for" do
    # §10 states the floor numerically ("≥ 1 minute"), and it is the one property that must
    # hold for every attempt count.
    it "never schedules sooner than the one-minute floor, whatever the jitter" do
      (1..10).each do |attempts|
        expect(backoff.delay_for(attempts)).to be >= described_class::BASE_SECONDS
      end
    end

    it "doubles with each attempt since the last success" do
      expect(no_jitter.delay_for(1)).to eq(60.0)
      expect(no_jitter.delay_for(2)).to eq(120.0)
      expect(no_jitter.delay_for(3)).to eq(240.0)
    end

    # A zero or negative count is a caller bug rather than a reason to retry instantly.
    it "treats a first attempt and a zeroth alike, so no count schedules an immediate retry" do
      expect(no_jitter.delay_for(0)).to eq(60.0)
    end

    # Capped *after* jitter, so MAX_SECONDS is an honest bound rather than a bound plus up
    # to 25 per cent.
    it "caps at one rate-limit window even at full jitter" do
      expect(full_jitter.delay_for(20)).to eq(described_class::MAX_SECONDS.to_f)
    end

    it "caps at one rate-limit window so a repeatedly failing row periodically rejoins the FIFO" do
      expect(described_class::MAX_SECONDS).to eq(3600)
    end

    # Additive only: subtracting could schedule a retry sooner than the floor, and the
    # floor is the property §10 states numerically.
    it "adds jitter rather than subtracting it, so the floor is never undercut" do
      expect(full_jitter.delay_for(1)).to eq(75.0)
      expect(no_jitter.delay_for(1)).to eq(60.0)
    end
  end

  describe "#retry_at" do
    it "projects the delay onto the instant the caller supplied" do
      expect(no_jitter.retry_at(1, now: frozen_time)).to eq(frozen_time + 60)
    end
  end
end
