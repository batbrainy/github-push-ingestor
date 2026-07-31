require "rails_helper"

# config/initializers/github.rb is the only thing that makes §10's "the allowance formula
# is computed at startup" true, and until this spec existed nothing referenced it: deleting
# the to_prepare registration left the whole suite green, because every example builds its
# own Github::Configuration and never depends on the one the boot resolved.
#
# The block is exercised through Rails.application.reloader.prepare!, which is what railties
# calls at boot (Finisher's :run_prepare_callbacks) and again on each development reload.
# Driving the real callback chain is the point — asserting against a proc pulled out of
# config.to_prepare_blocks would pass even if the registration were never installed.
RSpec.describe "the Github startup initializer" do
  def boot = Rails.application.reloader.prepare!

  # §11 puts budget state transitions at INFO, and this line is the one an operator reads
  # every other budget line against: it names the numbers the process is about to enforce
  # before it issues a request.
  it "logs the resolved allowances at boot" do
    expect(Rails.logger).to receive(:info).with(hash_including(
      event: "config.budget_resolved", mode: "live",
      poll_allowance: 12, enrichment_allowance: 40, reserve: 8
    ))

    boot
  end

  it "leaves Github.configuration validated and memoized for the process" do
    boot

    expect(Github.configuration.allowances).to have_attributes(poll_allowance: 12, enrichment_allowance: 40)
  end

  # The over-commitment the allowance formula cannot see: it counts one attempt per page,
  # while §10 makes every retry and every redirect hop its own reservation. A warning and
  # not a raise, because §10 requires runtime conditions to degrade rather than crash-loop.
  describe "the amplification warning" do
    # Built from an explicit hash rather than by mutating ENV, which would leak into
    # whichever example ran next under config.order = :random. The initializer calls
    # Github.reset! before Github.configuration, so stubbing the reader is what survives it.
    def stub_configuration(**environment)
      allow(Github).to receive(:configuration)
        .and_return(Github::Configuration.new(environment.transform_keys(&:to_s)))
    end

    it "warns when a single failing poll could out-spend the whole poll allowance" do
      # ceil(3600/3600) * 1 * 1 = 1 poll attempt/hour against a worst case of 9.
      stub_configuration("POLL_INTERVAL_SECONDS" => "3600")

      expect(Rails.logger).to receive(:warn).with(hash_including(
        event: "config.amplification", poll_allowance: 1
      ))

      boot
    end

    it "stays silent when the allowance covers the worst case" do
      stub_configuration

      expect(Rails.logger).not_to receive(:warn).with(hash_including(event: "config.amplification"))

      boot
    end
  end

  # The rejection §10 states outright: "Startup validation rejects any configuration where
  # poll_attempt_allowance + reserve >= effective_limit." Raising here stops the container
  # rather than letting it poll into an over-commitment.
  it "refuses to finish booting on a configuration that leaves no enrichment capacity" do
    allow(Github).to receive(:configuration)
      .and_return(Github::Configuration.new("POLL_INTERVAL_SECONDS" => "60", "MAX_PAGES_PER_POLL" => "2"))

    expect { boot }.to raise_error(Github::Errors::ConfigurationError)
  end
end
