require "rails_helper"

# §10's ENABLED_LIVE_SOURCE_COUNT read from event_sources rather than from the
# environment — ADR 0004's "dynamic multi-source allocation validation", assigned to this
# PR by name.
RSpec.describe Github::SourceAllocation do
  subject(:allocation) { described_class.new }

  def live_source(**overrides)
    create_event_source(source_type: "github_public_events", **overrides)
  end

  describe "#observed_count" do
    it "counts nothing on a clean checkout, because nothing seeds event_sources" do
      expect(allocation.observed_count(mode: "live")).to eq(0)
    end

    it "counts the rows of the mode's own source type" do
      live_source
      live_source

      expect(allocation.observed_count(mode: "live")).to eq(2)
    end

    # A development database routinely holds both types — the README's reviewer path
    # creates a github_fixture_events row — and a live process would provision poll
    # allowance for a source it will never poll.
    it "ignores rows belonging to the other mode's adapter" do
      live_source
      create_event_source(source_type: "github_fixture_events")

      expect(allocation.observed_count(mode: "live")).to eq(1)
      expect(allocation.observed_count(mode: "fixture")).to eq(1)
    end

    it "ignores a disabled source, which will never be polled" do
      live_source
      live_source(enabled: false)

      expect(allocation.observed_count(mode: "live")).to eq(1)
    end

    # §10 makes a failed source operator-recoverable only, and Github::IngestionRunner
    # refuses to poll one at all. Provisioning allowance for it would take requests away
    # from enrichment for a source that provably cannot spend them.
    it "ignores a failed source, which is operator-recoverable only" do
      live_source
      live_source(status: "failed")

      expect(allocation.observed_count(mode: "live")).to eq(1)
    end
  end

  describe "#live_source_count" do
    it "reports what the database holds rather than what the environment claims" do
      3.times { live_source }

      expect(allocation.live_source_count(mode: "live")).to eq(3)
    end

    # Not a floor over the observed count: an operator who disabled every source must not
    # have the variable quietly re-provision capacity for them. It is the answer only when
    # there is nothing to observe, which is a fresh install — SourceProvisioner creates the
    # row lazily at the point of use, so the ledger can genuinely ask before one exists.
    it "falls back to the configured count when no row exists yet" do
      expect(allocation.live_source_count(mode: "live"))
        .to eq(Github.configuration.enabled_live_source_count)
    end

    it "reports one enabled source out of a disabled crowd, not the configured number" do
      live_source
      2.times { live_source(enabled: false) }

      expect(described_class.new(configuration: configuration_with(ENABLED_LIVE_SOURCE_COUNT: "3"))
        .live_source_count(mode: "live")).to eq(1)
    end
  end

  describe "drift between the environment and the database" do
    before { allow(Rails.logger).to receive(:warn) }

    def drift_line = hash_including(event: "budget.source_allocation_drift")

    it "warns when the database holds more sources than the formula was configured for" do
      2.times { live_source }

      allocation.live_source_count(mode: "live")

      expect(Rails.logger).to have_received(:warn).with(
        hash_including(event: "budget.source_allocation_drift",
                       configured_source_count: 1, observed_source_count: 2,
                       configured_poll_allowance: 12, observed_poll_allowance: 24)
      )
    end

    # The mirror case, and the quieter one: 24 poll attempts reserved for a source count of
    # one leaves enrichment 28 instead of 40 for no reason at all.
    it "warns when the formula was configured for more sources than exist" do
      live_source
      configured = described_class.new(configuration: configuration_with(ENABLED_LIVE_SOURCE_COUNT: "2"))

      expect(configured.live_source_count(mode: "live")).to eq(1)

      expect(Rails.logger).to have_received(:warn).with(
        hash_including(event: "budget.source_allocation_drift",
                       configured_source_count: 2, observed_source_count: 1,
                       configured_poll_allowance: 24, observed_poll_allowance: 12)
      )
    end

    it "stays silent when the two agree" do
      live_source

      expect(allocation.live_source_count(mode: "live")).to eq(1)

      expect(Rails.logger).not_to have_received(:warn).with(drift_line)
    end

    # The fallback is not drift. A clean checkout has nothing to disagree with, and warning
    # on every reservation before the first poll would bury §11's stream on day one.
    it "stays silent when there is nothing to observe" do
      allocation.live_source_count(mode: "live")

      expect(Rails.logger).not_to have_received(:warn).with(drift_line)
    end
  end
end
