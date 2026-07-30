require "rails_helper"

# §16's reviewer-experience gate — "plain `docker compose up --build` starts exactly `db`,
# `setup`, `web`, `worker`" — is a property of a YAML file that nothing else in the suite
# asserts, and a single mistyped key silently breaks it. The `ingest` service is one profile
# key away from starting on every `up`, so it is checked here rather than by hand.
RSpec.describe "docker-compose.yml" do
  let(:compose) { YAML.safe_load(Rails.root.join("docker-compose.yml").read, aliases: true) }
  let(:services) { compose.fetch("services") }

  def unprofiled
    services.reject { |_name, service| service.key?("profiles") }.keys
  end

  # worker arrives with PR 8, when continuous polling starts.
  it "starts exactly db, setup and web on a plain up" do
    expect(unprofiled).to match_array(%w[db setup web])
  end

  it "keeps the one-shots behind the tools profile" do
    expect(services.fetch("ingest").fetch("profiles")).to eq([ "tools" ])
    expect(services.fetch("test").fetch("profiles")).to eq([ "tools" ])
  end

  describe "the ingest service" do
    let(:ingest) { services.fetch("ingest") }

    # §2A's topology table: profile tools, restart "no", depends_on setup
    # service_completed_successfully.
    it "never restarts, because a one-shot that restarts is a poller" do
      expect(ingest.fetch("restart")).to eq("no")
    end

    it "waits for the schema the development databases need" do
      expect(ingest.dig("depends_on", "setup", "condition")).to eq("service_completed_successfully")
      expect(ingest.dig("depends_on", "db", "condition")).to eq("service_healthy")
    end

    # An entrypoint with an explicitly empty command, so `docker compose run --rm ingest` and
    # `docker compose run --rm ingest --force` both work and the image's puma CMD can never
    # arrive as arguments.
    it "runs bin/ingest and passes any arguments straight through" do
      expect(ingest.fetch("entrypoint")).to eq([ "bin/ingest" ])
      expect(ingest.fetch("command")).to eq([])
    end

    # Unlike `test`, which pins GITHUB_MODE, the one-shot inherits the shared anchor — the
    # deterministic reviewer path depends on GITHUB_MODE=fixture reaching this container.
    it "inherits the shared environment so fixture mode reaches it" do
      expect(ingest.fetch("environment")).to include("GITHUB_MODE")
      expect(ingest.fetch("environment").fetch("GITHUB_MODE")).to eq("${GITHUB_MODE:-live}")
    end

    # Without these, `MAX_PAGES_PER_POLL=3 docker compose run --rm ingest` sets a variable
    # in the reviewer's shell and nothing at all inside the container, and the pagination
    # walk the README documents cannot be reproduced. They are in the shared anchor for the
    # same reason GITHUB_MODE is: §10's formula must come out the same in every process,
    # because one ledger serves all of them.
    it "forwards §10's allowance-formula inputs, so the documented overrides actually work" do
      environment = ingest.fetch("environment")

      expect(environment).to include(
        "POLL_INTERVAL_SECONDS" => "${POLL_INTERVAL_SECONDS:-300}",
        "MAX_PAGES_PER_POLL" => "${MAX_PAGES_PER_POLL:-1}",
        "ENABLED_LIVE_SOURCE_COUNT" => "${ENABLED_LIVE_SOURCE_COUNT:-1}",
        "RATE_LIMIT_RESERVE" => "${RATE_LIMIT_RESERVE:-8}"
      )
    end

    # The defaults in the anchor and the defaults the application falls back to have to be
    # the same numbers, or `docker compose run` and `bin/ingest` would disagree about the
    # budget split with nothing to catch it.
    it "declares the same defaults the application does" do
      environment = ingest.fetch("environment")

      Github::Configuration::DEFAULTS.slice("POLL_INTERVAL_SECONDS", "MAX_PAGES_PER_POLL",
                                            "ENABLED_LIVE_SOURCE_COUNT", "RATE_LIMIT_RESERVE")
                                     .each do |variable, default|
        expect(environment.fetch(variable)).to eq("${#{variable}:-#{default}}")
      end
    end
  end
end
