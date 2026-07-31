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

  # Everything below is what §16's durability gate — "Docker restart policies recover crashed
  # db/web/worker containers automatically (verified by container kills)" — actually rests on.
  # script/verify_recovery.sh proves the runtime behaviour once, on one host, on one date.
  # These examples prove the declarations that behaviour comes from, on every push, and they
  # are the reason a compose edit cannot silently invalidate the committed transcript.
  describe "the db service" do
    let(:db) { services.fetch("db") }

    it "pins the PostgreSQL major version the schema was written against" do
      expect(db.fetch("image")).to eq("postgres:16")
    end

    it "restarts after a crash, because the transcript's db kill depends on it" do
      expect(db.fetch("restart")).to eq("unless-stopped")
    end

    # §8's "PostgreSQL will use a named Docker volume", and the distinction is the whole
    # point: an anonymous volume or a bind mount also survives `docker kill` and `docker
    # compose restart`, so a count check after either would pass. It is `docker compose down`
    # and recreation that tells them apart, and only a *named* volume survives that.
    it "keeps its data in a named volume, not an anonymous one or a bind mount" do
      expect(db.fetch("volumes")).to eq([ "pgdata:/var/lib/postgresql/data" ])
      expect(compose.fetch("volumes").keys).to eq([ "pgdata" ])
    end

    # -h 127.0.0.1 is load-bearing and easy to "simplify" away. postgres's first-boot initdb
    # runs a temporary server that answers pg_isready on the unix socket only, so a socket
    # check reports healthy before the real server accepts TCP — and every
    # `service_healthy` gate in this file would then release too early.
    it "probes over TCP, so first-boot initdb cannot report healthy early" do
      expect(db.dig("healthcheck", "test")).to eq([ "CMD-SHELL", "pg_isready -U postgres -h 127.0.0.1" ])
    end

    # Pinned because `setup`, `web` and `worker` all gate on this probe: the timings decide
    # how long a recovering stack waits before it gives up on the database.
    it "declares the timings every service_healthy gate derives from" do
      expect(db.fetch("healthcheck")).to include(
        "interval" => "5s", "timeout" => "3s", "retries" => 10, "start_period" => "10s"
      )
    end
  end

  describe "the web service" do
    let(:web) { services.fetch("web") }

    # The sharpest assertion in this file. `bin/rails server` writes tmp/pids/server.pid, and
    # as PID 1 in a container a stale pid file left by an ungraceful kill blocks every
    # subsequent boot — which defeats `unless-stopped` precisely in the case it exists for.
    # The Dockerfile carries the same note against its CMD. A future "simplification" back to
    # `bin/rails server` has to fail here, because the symptom otherwise appears only after a
    # crash, in a container that will not come back.
    it "runs puma directly, so no pid file can survive a kill and block the restart" do
      expect(web.fetch("command")).to eq([ "bundle", "exec", "puma", "-C", "config/puma.rb" ])
      expect(web).not_to have_key("entrypoint")
      expect(web.fetch("command")).not_to include("rails", "server")
    end

    it "restarts after a crash" do
      expect(web.fetch("restart")).to eq("unless-stopped")
    end

    it "publishes the port the README's health checks use" do
      expect(web.fetch("ports")).to eq([ "3000:3000" ])
    end

    # Liveness, never readiness. A readiness-based container healthcheck would mark web
    # unhealthy for as long as a killed db took to come back — so Docker would report the
    # symptom of the db kill on the wrong service, and §15 step 8's `docker compose ps`
    # would read as though web had also failed. /health/ready is the observable that flips;
    # the container probe deliberately is not.
    it "probes liveness, so a db kill is not misreported as a web failure" do
      expect(web.dig("healthcheck", "test")).to eq(
        [ "CMD", "curl", "-fsS", "http://localhost:3000/health/live" ]
      )
    end

    it "waits for the schema both databases need" do
      expect(web.dig("depends_on", "db", "condition")).to eq("service_healthy")
      expect(web.dig("depends_on", "setup", "condition")).to eq("service_completed_successfully")
    end
  end

  describe "the setup service" do
    let(:setup) { services.fetch("setup") }

    it "prepares both databases declared in config/database.yml" do
      expect(setup.fetch("command")).to eq([ "bin/rails", "db:prepare" ])
    end

    # A `setup` that restarted would run db:prepare again every time the stack recovered,
    # racing the web and worker containers it exists to unblock.
    it "never restarts, so recovery cannot re-run a migration step" do
      expect(setup.fetch("restart")).to eq("no")
    end

    it "runs on a plain up, unlike the tools-profiled one-shots" do
      expect(setup).not_to have_key("profiles")
    end
  end

  # §16's reviewer-experience gate: "docker compose run --rm test never touches the
  # development databases (app or queue) and never triggers the development setup service."
  # Nothing asserted it before this PR, in a file or at runtime.
  describe "the test service" do
    let(:test) { services.fetch("test") }

    # Literal, never the anchor's ${RAILS_ENV:-development}. The suite would probably still
    # land on the test databases through spec/rails_helper.rb's RAILS_ENV default — but a
    # §16 gate must not depend on that reasoning holding somewhere else.
    it "pins the test environment rather than inheriting the development default" do
      expect(test.fetch("environment").fetch("RAILS_ENV")).to eq("test")
    end

    # Pinned so `GITHUB_MODE=fixture docker compose run --rm test` cannot quietly run a
    # different suite than CI does.
    it "pins live mode, so a reviewer's fixture-mode shell cannot change what CI ran" do
      expect(test.fetch("environment").fetch("GITHUB_MODE")).to eq("live")
    end

    # The gate, as one assertion: adding `setup` here would run db:prepare against the
    # *development* databases as a side effect of running the test suite.
    it "depends on db alone, never on the development setup service" do
      expect(test.fetch("depends_on").keys).to eq([ "db" ])
      expect(test.dig("depends_on", "db", "condition")).to eq("service_healthy")
    end

    # Asserted structurally rather than as an exact command. What §16's gate needs is that the
    # *test* databases are prepared before anything runs and that the development preparer is
    # never invoked — not that the command has a particular number of steps. Freezing the
    # literal string makes every later addition to the pipeline a false failure, which is how
    # this example broke once already: PR 9 appended `bundle exec rspec spec/stress`, and an
    # equality assertion written before it turned a green branch red on merge.
    it "prepares its own isolated databases before running anything" do
      command = test.fetch("command")
      script = command.last

      expect(command.first(2)).to eq([ "bash", "-c" ])
      expect(script).to start_with("bin/rails db:test:prepare")
      expect(script).to include("bundle exec rspec")
    end

    # `db:prepare` is the development preparer; `db:test:prepare` does not contain it as a
    # substring, so this is an exact statement of "the test service never prepares the
    # development databases".
    it "never invokes the development database preparer" do
      expect(test.fetch("command").last).not_to include("db:prepare")
    end

    it "never restarts" do
      expect(test.fetch("restart")).to eq("no")
    end

    # Catches both drift directions in one line: a variable added to the shared anchor that
    # `test` should have inherited, and a third override slipped in beside the two intended
    # ones.
    it "differs from the one-shots by exactly the two overrides it declares" do
      expect(test.fetch("environment")).to eq(
        services.fetch("ingest").fetch("environment")
                .merge("RAILS_ENV" => "test", "GITHUB_MODE" => "live")
      )
    end
  end

  describe "restart policies, as a set" do
    # Stated as a partition rather than service by service, so a service added later cannot
    # land in neither list unnoticed.
    it "declares unless-stopped on exactly the long-running services" do
      always_on = services.select { |_name, service| service["restart"] == "unless-stopped" }.keys

      expect(always_on).to match_array(%w[db web worker])
    end

    it "declares no on every one-shot" do
      one_shots = services.select { |_name, service| service["restart"] == "no" }.keys

      expect(one_shots).to match_array(%w[setup ingest enrich test])
    end

    # The real guard. Docker's default policy is `no`, so an *omitted* restart key on a
    # long-running service loses crash recovery silently — there is no error, no warning,
    # and the container simply stays dead the first time it is killed.
    it "leaves the policy implicit nowhere, because Docker's default would lose recovery" do
      missing = services.reject { |_name, service| service.key?("restart") }.keys

      expect(missing).to be_empty
    end
  end

  # A killed worker restarts on whatever `github-push-ingestor-app` currently is. If one
  # service built a different tag, the container that came back would not be the one the
  # recovery transcript was produced against.
  describe "the shared application image" do
    let(:app_services) { %w[setup web worker ingest enrich test] }

    it "runs every application service from one image" do
      app_services.each do |name|
        expect(services.fetch(name).fetch("image")).to eq("github-push-ingestor-app")
      end
    end

    # The invariant that keeps a reviewer's first command working. Compose Bake — on by
    # default in Docker Desktop — makes every service with a `build:` its own bake target,
    # and two targets exporting the same `image:` tag race: a cold `docker compose up
    # --build` failed with `image "github-push-ingestor-app:latest": already exists` and
    # started nothing. It reproduces only when the image is absent, so it is invisible on
    # every machine except the one that matters.
    #
    # `up` starts setup, web and worker; exactly one of them may declare a build.
    it "declares exactly one build among the services a plain `up` starts" do
      builders = %w[setup web worker].select { |name| services.fetch(name).key?("build") }

      expect(builders).to eq(%w[setup])
    end

    # web and worker are safe without a build only because they wait for the service that
    # has one. Without this, a cold `up` would try to pull a tag that was never published.
    it "makes the buildless services wait for the one that builds" do
      %w[web worker].each do |name|
        expect(services.fetch(name).fetch("depends_on").fetch("setup"))
          .to include("condition" => "service_completed_successfully")
      end
    end

    # Each `tools` one-shot is invoked alone by `docker compose run`, so it is a single
    # bake target and cannot collide — it keeps its own build and must, because nothing
    # else builds the image on that path. pull_policy stops Compose from attempting a
    # registry pull of a tag that is local-only by construction.
    it "lets each one-shot build for itself without reaching for a registry" do
      %w[ingest enrich test].each do |name|
        expect(services.fetch(name).fetch("build")).to eq(".")
        expect(services.fetch(name).fetch("pull_policy")).to eq("build")
      end
    end
  end

  # The same rule spec/network_boundary_spec.rb applies to the live rate-limit probe under
  # script/, for the same reason: script/verify_recovery.sh kills containers and writes to the
  # *development* databases, so "CI never runs it" has to be a red test rather than a promise.
  #
  # That spec greps every file under spec/ for the probe's name, so this comment names it
  # obliquely on purpose — spelling it out here would turn its guard red.
  #
  # It lives here rather than beside the probe guard because that spec's subject is the
  # network boundary, and this script makes no network calls at all — fixture mode is one of
  # its preflight requirements.
  describe "script/verify_recovery.sh" do
    it "exists and is executable, because the README tells a reviewer to run it" do
      script = Rails.root.join("script/verify_recovery.sh")

      expect(script).to exist
      expect(script).to be_executable
    end

    it "is referenced by no workflow, no compose service, and no CI entry point" do
      reachable = Dir[Rails.root.join(".github/workflows/*.yml")] +
                  [ Rails.root.join("config/ci.rb").to_s,
                    Rails.root.join("bin/ci").to_s,
                    Rails.root.join("docker-compose.yml").to_s ]

      referencing = reachable.select do |path|
        File.file?(path) && File.read(path).include?("verify_recovery")
      end

      expect(referencing).to be_empty
    end
  end
end
