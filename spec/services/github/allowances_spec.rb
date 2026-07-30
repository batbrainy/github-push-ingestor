require "rails_helper"

RSpec.describe Github::Allowances do
  def configuration(**overrides)
    Github::Configuration.new(overrides.transform_keys(&:to_s))
  end

  describe "the one authoritative formula (plan §10)" do
    it "derives twelve poll attempts an hour from the pinned defaults" do
      expect(described_class.derive(configuration: configuration, limit: 60).poll_allowance).to eq(12)
    end

    it "derives forty enrichment attempts as limit minus reserve minus polling" do
      expect(described_class.derive(configuration: configuration, limit: 60).enrichment_allowance).to eq(40)
    end

    # A 450-second cadence fits seven whole intervals in an hour plus a remainder, and
    # the eighth poll still happens. Rounding down would under-reserve polling and let
    # enrichment spend the attempt polling needed.
    it "rounds the hourly poll count up, because a partial interval still polls" do
      derived = described_class.derive(configuration: configuration(POLL_INTERVAL_SECONDS: "450"), limit: 60)

      expect(derived.poll_allowance).to eq(8)
    end

    it "multiplies by the page cap, because each page is its own request attempt" do
      derived = described_class.derive(configuration: configuration(MAX_PAGES_PER_POLL: "3"), limit: 60)

      expect(derived.poll_allowance).to eq(36)
    end

    it "multiplies by the enabled live source count, which shares one per-IP budget" do
      derived = described_class.derive(configuration: configuration(ENABLED_LIVE_SOURCE_COUNT: "2"), limit: 60)

      expect(derived.poll_allowance).to eq(24)
    end

    it "reports a negative enrichment allowance rather than hiding an over-commitment" do
      derived = described_class.derive(configuration: configuration(POLL_INTERVAL_SECONDS: "60"), limit: 60)

      expect(derived.enrichment_allowance).to eq(-8)
    end
  end

  describe "#feasible?" do
    it "accepts the pinned defaults, which leave forty enrichment attempts" do
      expect(described_class.derive(configuration: configuration, limit: 60)).to be_feasible
    end

    # Plan §10 rejects on >=, not >: a configuration that leaves exactly zero
    # enrichment capacity cannot satisfy Story 3 either.
    it "rejects a split that leaves exactly zero enrichment capacity" do
      derived = described_class.derive(configuration: configuration(RATE_LIMIT_RESERVE: "48"), limit: 60)

      expect(derived.enrichment_allowance).to eq(0)
      expect(derived).not_to be_feasible
    end

    it "rejects a polling requirement that exceeds the limit outright" do
      expect(described_class.derive(configuration: configuration(POLL_INTERVAL_SECONDS: "60"), limit: 60))
        .not_to be_feasible
    end
  end

  describe "#clamped" do
    it "leaves a feasible derivation untouched" do
      derived = described_class.derive(configuration: configuration, limit: 60)

      expect(derived.clamped).to eq(derived)
    end

    # A live x-ratelimit-limit lower than the configured default is GitHub's business,
    # not an operator error, so runtime degrades instead of crash-looping the worker.
    # Polling wins the clamp because enrichment reaching zero is a documented outcome
    # while polling stopping is a Story 1 failure.
    it "keeps polling whole and gives enrichment what is left when the limit is lower" do
      clamped = described_class.derive(configuration: configuration, limit: 15).clamped

      expect(clamped.poll_allowance).to eq(7)
      expect(clamped.enrichment_allowance).to eq(0)
    end

    it "never derives a negative allowance, which the schema's CHECK would reject" do
      clamped = described_class.derive(configuration: configuration, limit: 4).clamped

      expect(clamped.poll_allowance).to eq(0)
      expect(clamped.enrichment_allowance).to eq(0)
    end
  end
end
