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

  it "starts exactly db, setup, web and worker on a plain up" do
    expect(unprofiled).to match_array(%w[db setup web worker])
  end

  it "keeps the one-shots behind the tools profile" do
    expect(services.fetch("ingest").fetch("profiles")).to eq([ "tools" ])
    expect(services.fetch("enrich").fetch("profiles")).to eq([ "tools" ])
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

    # ACTOR_ENRICHMENT_SHARE decides how the ledger splits the enrichment allowance under
    # its row lock, and the three timings decide which candidates are *currently eligible*
    # — which is the input to the borrow decision the ledger then acts on. Two processes
    # reading different values would enforce different policies against one row.
    it "forwards §10's fairness share and enrichment timings, so one ledger sees one policy" do
      environment = ingest.fetch("environment")

      expect(environment).to include(
        "ACTOR_ENRICHMENT_SHARE" => "${ACTOR_ENRICHMENT_SHARE:-0.50}",
        "ENRICHMENT_ELIGIBILITY_WINDOW_SECONDS" => "${ENRICHMENT_ELIGIBILITY_WINDOW_SECONDS:-3600}",
        "ACTOR_REFRESH_TTL_SECONDS" => "${ACTOR_REFRESH_TTL_SECONDS:-86400}",
        "REPOSITORY_REFRESH_TTL_SECONDS" => "${REPOSITORY_REFRESH_TTL_SECONDS:-86400}"
      )
    end

    # The defaults in the anchor and the defaults the application falls back to have to be
    # the same numbers, or `docker compose run` and `bin/ingest` would disagree about the
    # budget split with nothing to catch it.
    #
    # Sliced by what the anchor actually forwards rather than by a hardcoded list, so a
    # variable added to one side and not the other cannot slip past unasserted.
    it "declares the same defaults the application does, for every variable it forwards" do
      environment = ingest.fetch("environment")

      Github::Configuration::DEFAULTS.slice(*environment.keys).each do |variable, default|
        expect(environment.fetch(variable)).to eq("${#{variable}:-#{default}}")
      end
    end
  end

  # §2A's topology table, and the service that makes this system run by itself: one Solid
  # Queue supervisor per container, running the poll tick, the enrichment jobs and the
  # reconciler.
  describe "the worker service" do
    let(:worker) { services.fetch("worker") }

    it "runs the Solid Queue supervisor" do
      expect(worker.fetch("command")).to eq([ "bin/jobs" ])
      expect(worker).not_to have_key("entrypoint")
    end

    # Docker's default policy is `no`, so §2A's crash recovery has to be declared. This is
    # the service whose death would silently stop all ingestion.
    it "restarts after a crash, like the other long-running services" do
      expect(worker.fetch("restart")).to eq("unless-stopped")
    end

    # 30s pairs with SolidQueue.shutdown_timeout (20s in config/application.rb, itself
    # HTTP_OPEN_TIMEOUT_SECONDS + HTTP_READ_TIMEOUT_SECONDS), leaving margin for the
    # supervisor to reap its children.
    it "gives in-flight GitHub work time to finish on the way down" do
      expect(worker.fetch("stop_grace_period")).to eq("30s")
    end

    it "waits for the schema both databases need" do
      expect(worker.dig("depends_on", "setup", "condition")).to eq("service_completed_successfully")
      expect(worker.dig("depends_on", "db", "condition")).to eq("service_healthy")
    end

    # One ledger row serves every process, so the worker has to read the same §10 policy the
    # one-shots do. A worker on a different ACTOR_ENRICHMENT_SHARE would enforce a second
    # policy against the same row.
    it "inherits the same shared environment the one-shots do" do
      expect(worker.fetch("environment")).to eq(services.fetch("ingest").fetch("environment"))
    end

    # Nothing depends on this service, `unless-stopped` already covers process death, and the
    # only probe that could tell a hung worker from a busy one would have to boot Rails on
    # every interval; solid_queue_processes heartbeats are the durable evidence instead.
    it "declares no healthcheck, unlike web" do
      expect(worker).not_to have_key("healthcheck")
    end
  end

  # §5's two request paths, and §13's PR 7. A separate service rather than a flag on
  # `ingest`, because enrichment belongs to no event source, takes no source lock, and
  # spends a different class of the budget.
  describe "the enrich service" do
    let(:enrich) { services.fetch("enrich") }

    it "never restarts, because a one-shot that restarts is a worker" do
      expect(enrich.fetch("restart")).to eq("no")
    end

    it "waits for the schema the development databases need" do
      expect(enrich.dig("depends_on", "setup", "condition")).to eq("service_completed_successfully")
      expect(enrich.dig("depends_on", "db", "condition")).to eq("service_healthy")
    end

    it "runs bin/enrich and passes any arguments straight through" do
      expect(enrich.fetch("entrypoint")).to eq([ "bin/enrich" ])
      expect(enrich.fetch("command")).to eq([])
    end

    # The deterministic reviewer path depends on GITHUB_MODE=fixture reaching this
    # container, exactly as it does for ingest.
    it "inherits the same shared environment the ingest one-shot does" do
      expect(enrich.fetch("environment")).to eq(services.fetch("ingest").fetch("environment"))
    end
  end
end
