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
      poll_allowance: 12, enrichment_allowance: 40, reserve: 8,
      actor_guarantee: 20, repository_guarantee: 20
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

  # The rejection Appendix F restates for the staged budget: polling, the configured
  # detail-fallback allowance, and the reserve must fit inside the core limit together.
  # Raising here stops the container rather than letting it poll into an over-commitment,
  # and the message names CORE_DETAIL_FALLBACK_ALLOWANCE among the levers an operator
  # can move.
  it "refuses to finish booting on a configuration whose commitments exceed the core limit" do
    allow(Github).to receive(:configuration)
      .and_return(Github::Configuration.new("POLL_INTERVAL_SECONDS" => "60", "MAX_PAGES_PER_POLL" => "2"))

    expect { boot }.to raise_error(Github::Errors::ConfigurationError, /CORE_DETAIL_FALLBACK_ALLOWANCE/)
  end

  # Appendix F's structural rules run in the same boot-time validation, so a container
  # with a lease its own worst-case fetch could outlive never starts.
  it "refuses to finish booting on a staged-enrichment rule violation" do
    allow(Github).to receive(:configuration)
      .and_return(Github::Configuration.new("ENRICHMENT_LEASE_SECONDS" => "585"))

    expect { boot }.to raise_error(Github::Errors::ConfigurationError, /ENRICHMENT_LEASE_SECONDS/)
  end
end
