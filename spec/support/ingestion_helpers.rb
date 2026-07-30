# Envelope builders for the ingestion write path (IMPLEMENTATION_PLAN.md §7, §12).
#
# §7's taxonomy needs roughly thirty near-identical envelopes that differ in one field
# each. Written out longhand, the one field that matters disappears into twenty-five lines
# of context, so the base envelope lives here and each example states only its deviation.
#
# The base is corpus event 58000000001 verbatim (fixtures/github/bodies/events/page-1.json),
# so a spec built from it is a spec about the real payload shape and not about an
# invented one. A fresh Hash is returned on every call, so an example may mutate or delete
# from it freely — which is how a *missing* field is expressed, since deep_merge cannot
# remove one.
module IngestionHelpers
  ACTOR_GITHUB_ID = 583_231
  REPOSITORY_GITHUB_ID = 1_296_269

  def well_formed_envelope(overrides = {})
    {
      "id" => "58000000001",
      "type" => Github::Events::PushEventProcessor::EVENT_TYPE,
      "actor" => {
        "id" => ACTOR_GITHUB_ID,
        "login" => "octocat",
        "display_login" => "octocat",
        "gravatar_id" => "",
        "url" => "https://api.github.com/users/octocat",
        "avatar_url" => "https://avatars.githubusercontent.com/u/583231?"
      },
      "repo" => {
        "id" => REPOSITORY_GITHUB_ID,
        "name" => "octocat/Hello-World",
        "url" => "https://api.github.com/repos/octocat/Hello-World"
      },
      "payload" => {
        "repository_id" => REPOSITORY_GITHUB_ID,
        "push_id" => 27_500_000_001,
        "ref" => "refs/heads/main",
        "head" => "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0",
        "before" => "0f9e8d7c6b5a4938271605f4e3d2c1b0a9988776"
      },
      "public" => true,
      "created_at" => "2026-07-29T11:58:12Z"
    }.deep_merge(overrides.deep_stringify_keys)
  end

  # The eight envelopes of page 1, decoded — the exact input every expected count in the
  # integration specs is derived from.
  def corpus_page(name)
    JSON.parse(Rails.root.join("fixtures", "github", "bodies", "events", name).read)
  end

  # A transport with its own scripted-response cursor. Github::Transports::Fixture keeps
  # cursors on the instance, "so two transports never share a script position" — which is
  # what makes a *second* transport a faithful model of a second one-shot process, and
  # therefore how the replay case is exercised without touching the corpus.
  def fixture_transport(scenario: "default")
    Github::Transports::Fixture.new(corpus: corpus(scenario: scenario), clock: -> { frozen_time })
  end

  # The real executor — gate, ledger, URL policy — over an offline transport. Only the
  # sleeper and the clocks are replaced, so retry and deferral contracts are asserted in
  # zero wall-clock time.
  def fixture_executor(transport: fixture_transport, **overrides)
    Github::RequestExecutor.new(
      transport: transport, mode: :fixture, sleeper: ->(_seconds) { },
      clock: -> { frozen_time }, **overrides
    )
  end

  def fixture_runner(transport: fixture_transport, now: frozen_time, executor: nil, writer: nil,
                     configuration: nil, **overrides)
    configuration ||= Github.configuration

    Github::IngestionRunner.new(
      executor: executor || fixture_executor(transport: transport, ledger: ledger_for(configuration), **overrides),
      writer: writer || Github::Ingestion::PageWriter.new(clock: -> { now }),
      configuration: configuration,
      clock: -> { now },
      monotonic: -> { 0.0 }
    )
  end

  # A configuration that differs from the process-wide one has to reach the ledger too,
  # not only the page loop. RequestExecutor builds BudgetLedger.new with no argument, so a
  # runner capped at three pages would otherwise be metered by a ledger still deriving
  # poll_allowance from MAX_PAGES_PER_POLL=1 — the two would disagree in specs while
  # agreeing in production, which is the worst way for a test to be green.
  def ledger_for(configuration)
    Github::BudgetLedger.new(configuration: configuration)
  end

  # §10's formula inputs are read once, at Configuration.new, and the object is frozen —
  # so a pagination example changes them by building a configuration, never by touching
  # ENV.
  def configuration_with(**overrides)
    Github::Configuration.new(Github::Configuration::DEFAULTS.merge(overrides.stringify_keys))
  end

  def fixture_event_source
    Github::Ingestion::SourceProvisioner.ensure!(mode: :fixture, now: frozen_time)
  end

  # The enrichment counterpart of #fixture_runner: the real ledger, gate and URL policy
  # over the offline transport, with only the clocks and the sleeper replaced. The same
  # ledger_for caveat applies — a custom configuration has to reach the ledger, or the
  # runner and the ledger would disagree in specs while agreeing in production.
  def fixture_enrichment_runner(transport: fixture_transport, now: frozen_time,
                                configuration: nil, executor: nil, **overrides)
    configuration ||= Github.configuration
    selector = Github::Enrichment::CandidateSelector.new(configuration: configuration)

    Github::EnrichmentRunner.new(
      executor: executor || fixture_executor(transport: transport, ledger: ledger_for(configuration)),
      configuration: configuration,
      clock: -> { now },
      monotonic: -> { 0.0 },
      selector: selector,
      # No jitter, so a scheduled retry is an instant a spec can name rather than a range.
      entity_state: Github::Enrichment::EntityState.new(
        backoff: Github::Enrichment::Backoff.new(random: Struct.new(:value) { def rand(*) = 0.0 }.new)
      ),
      **overrides
    )
  end
end

RSpec.configure do |config|
  config.include IngestionHelpers
end
