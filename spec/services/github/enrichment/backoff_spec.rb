require "rails_helper"

RSpec.describe Github::Enrichment::Backoff do
  # Injected rather than stubbed, so the schedule is asserted without sleeping and without
  # reaching into Kernel — the technique Github::PollBackoff's own spec uses.
  subject(:backoff) { described_class.new(random: Random.new(1234)) }

  def no_jitter(**options)
    described_class.new(random: instance_double(Random, rand: 0.0), **options)
  end

  def full_jitter(**options)
    described_class.new(random: instance_double(Random, rand: 1.0), **options)
  end

  describe "the configured ladder" do
    # Issue #45 makes the retry ladder configurable; the constants remain as the documented
    # defaults ENRICHMENT_RETRY_BASE_SECONDS / ENRICHMENT_RETRY_MAX_SECONDS start from, and
    # the two sources must not drift apart.
    it "defaults to the one-minute floor and the one-window cap" do
      configured = no_jitter(configuration: configuration_with)

      expect(configured.base_seconds).to eq(60)
      expect(configured.max_seconds).to eq(3600)
      expect(configured.base_seconds).to eq(described_class::BASE_SECONDS)
      expect(configured.max_seconds).to eq(described_class::MAX_SECONDS)
    end

    it "reads a tuned ladder from the configuration" do
      configured = no_jitter(configuration: configuration_with(
        "ENRICHMENT_RETRY_BASE_SECONDS" => "30", "ENRICHMENT_RETRY_MAX_SECONDS" => "120"
      ))

      expect(configured.delay_for(1)).to eq(30.0)
      expect(configured.delay_for(2)).to eq(60.0)
      expect(configured.delay_for(3)).to eq(120.0)
      expect(configured.delay_for(4)).to eq(120.0)
    end

    it "lets explicit keyword arguments override the configuration" do
      configured = no_jitter(base_seconds: 10, max_seconds: 40,
                             configuration: configuration_with(
                               "ENRICHMENT_RETRY_BASE_SECONDS" => "900"
                             ))

      expect(configured.delay_for(1)).to eq(10.0)
      expect(configured.delay_for(2)).to eq(20.0)
      expect(configured.delay_for(3)).to eq(40.0)
    end

    # With both bounds supplied there is nothing left to read, so the process-wide
    # configuration must not be touched — a spec-built Backoff with explicit bounds must
    # not depend on the environment it happens to run in.
    it "never reads the process configuration when both bounds are explicit" do
      expect(Github).not_to receive(:configuration)

      expect(no_jitter(base_seconds: 10, max_seconds: 40).delay_for(1)).to eq(10.0)
    end
  end

  describe "#delay_for" do
    # §10 states the floor numerically ("≥ 1 minute"), and it is the one property that must
    # hold for every attempt count.
    it "never schedules sooner than the configured floor, whatever the jitter" do
      (1..10).each do |attempts|
        expect(backoff.delay_for(attempts)).to be >= backoff.base_seconds
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

    # Capped *after* jitter, so max_seconds is an honest bound rather than a bound plus up
    # to 25 per cent.
    it "caps at the configured maximum even at full jitter" do
      expect(full_jitter.delay_for(20)).to eq(3600.0)
    end

    it "honours the cap even when jitter alone would exceed it" do
      tight = full_jitter(configuration: configuration_with(
        "ENRICHMENT_RETRY_BASE_SECONDS" => "60", "ENRICHMENT_RETRY_MAX_SECONDS" => "70"
      ))

      # 60 + 25% jitter is 75; the configured 70-second cap still binds.
      expect(tight.delay_for(1)).to eq(70.0)
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
