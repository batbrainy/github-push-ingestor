require "rails_helper"
require "tmpdir"

# Extension D's twelfth child issue asks for fixture-mode end-to-end verification and states
# the property it has to demonstrate: "fixture mode fails closed, never a live fallback".
#
# The container half of that — that the web, worker and ingest services make no egress with
# GITHUB_MODE=fixture — is script/verify_recovery.sh's, because nothing inside
# `bundle exec rspec` can observe a process it did not start. This file is the half that
# needs no Docker at all, because failing closed is a property of the application's own
# wiring: Github.transport, EventSources::Base.for_mode, UrlPolicy::MODES,
# Transports::Fixture#get, and RequestExecutor's deliberate decision not to rescue a miss.
#
# Each of those is asserted individually elsewhere. What is asserted here is that they move
# *together* — a mode is not one switch but three coupled decisions, and the failure this
# file exists to catch is one of them being changed without the others.
RSpec.describe "fixture mode fails closed" do
  describe "the three decisions GITHUB_MODE makes at once" do
    it "selects the offline transport and the offline event source from the same value" do
      expect(Github::EventSources::Base.for_mode(:fixture)).to eq(Github::EventSources::FixtureEvents)
      expect(Github::EventSources::Base.for_mode(:live)).to eq(Github::EventSources::PublicEvents)
      expect(Github::UrlPolicy::MODES.keys).to match_array(%i[ live fixture ])
    end

    # The offline address cannot leak into a live deployment: it is not merely unusual
    # under the live policy, it is refused by it.
    it "refuses the fixture source's own page-one URL under the live policy" do
      result = Github::UrlPolicy.validate(Github::EventSources::FixtureEvents::FIRST_PAGE_URL, mode: :live)

      expect(result.violations).to include(:scheme_not_allowed)
    end

    it "refuses a live api.github.com URL under the fixture policy" do
      result = Github::UrlPolicy.validate("https://api.github.com/events?per_page=100", mode: :fixture)

      expect(result.violations).to include(:scheme_not_allowed)
    end

    # Asserted as a pair on purpose. Either transport accepting the other mode's URL would
    # turn a mode mismatch into a request, and the symmetry is the guarantee.
    it "makes each transport refuse the other mode's validated URL at its door" do
      expect { Github::Transports::Faraday.new.get(fixture_url("/events?per_page=100")) }
        .to raise_error(ArgumentError, /live transport accepts only a live/)

      expect { fixture_transport.get(live_url("/events?per_page=100")) }
        .to raise_error(ArgumentError, /fixture transport accepts only a fixture/)
    end

    # §10 puts the allowed host in code rather than in the environment, "because an env var
    # here would turn the SSRF boundary into a deployment setting". Asserted against the
    # configuration's own key list so adding one would fail here rather than in review.
    it "keeps the allowed host out of the configuration entirely" do
      expect(Github::Configuration::DEFAULTS.values).not_to include(Github::UrlPolicy::ALLOWED_HOST)
      expect(Github::Configuration::DEFAULTS.keys.grep(/HOST|BASE_URL|ENDPOINT/)).to be_empty
      expect(Github::UrlPolicy::ALLOWED_HOST).to eq("api.github.com")
    end
  end

  # A corpus that resolves nothing the run needs. §6 says an unknown URL "raises a fixture
  # error, never a live fallback", and RequestExecutor states why it must not be converted
  # into a FetchResult: "a corpus gap is an authoring bug, not a runtime outcome, and
  # laundering it into a failed fetch would let a fixture-mode demo report a plausible-looking
  # failure instead of naming the missing entry."
  #
  # Proved through the real chain rather than by stubbing something to raise — which is what
  # separates this from spec/services/github/ingestion/one_shot_spec.rb's exit-code example.
  describe "a corpus with no entry for the request" do
    around do |example|
      Dir.mktmpdir do |directory|
        @gapped_root = Pathname.new(directory)
        @gapped_root.join("manifest.json").write(
          JSON.generate(
            version: 1,
            default_headers: {},
            # Deliberately not /events: the poll's own URL is the one that must miss.
            scenarios: { default: { responses: { "/users/nobody" => [ { status: 404 } ] } } }
          )
        )
        example.run
      end
    end

    let(:gapped_transport) do
      Github::Transports::Fixture.new(
        corpus: Github::FixtureCorpus.new(root: @gapped_root, scenario: "default"),
        clock: -> { frozen_time }
      )
    end

    before { active_budget_window(now: frozen_time) }

    it "raises rather than reaching GitHub" do
      expect { fixture_runner(transport: gapped_transport).call(event_source: fixture_event_source) }
        .to raise_error(Github::Errors::FixtureMiss, /defines no response for/)
    end

    it "names the missing key, so the corpus can be fixed without guessing" do
      fixture_runner(transport: gapped_transport).call(event_source: fixture_event_source)
    rescue Github::Errors::FixtureMiss => error
      expect(error.message).to include("/events?per_page=100")
    end

    # The miss reaches the caller as an exception, so it can never be reported as a poll
    # that happened and failed.
    it "records no successful run and persists nothing" do
      begin
        fixture_runner(transport: gapped_transport).call(event_source: fixture_event_source)
      rescue Github::Errors::FixtureMiss
        nil
      end

      expect(PushEvent.count).to eq(0)
      expect(IngestionRun.where(status: "completed")).to be_empty
    end

    # §9's exit-code contract: 2 is "refused to run — bad option, bad configuration, or a
    # corpus gap", and a corpus gap must never be reported as 0.
    it "makes the one-shot refuse with exit 2 rather than report a deferral" do
      one_shot = Github::Ingestion::OneShot.new(
        argv: [], output: StringIO.new, error_output: StringIO.new,
        runner: fixture_runner(transport: gapped_transport),
        provisioner: double(ensure!: fixture_event_source)
      )

      result = one_shot.call

      expect(result.exit_code).to eq(Github::Ingestion::OneShot::REFUSED)
      expect(result.outcome).to eq(:refused)
    end

    it "lists the corpus errors among the ones that refuse rather than defer" do
      expect(Github::Ingestion::OneShot::REFUSING_ERRORS).to include(
        Github::Errors::FixtureMiss, Github::Errors::FixtureCorpusError
      )
    end
  end

  # §12's end-to-end claim, in its executable form: "known corpus in, exact expected counts
  # out … zero live quota consumed". The suite already refuses net connect globally
  # (spec/network_boundary_spec.rb), so what this adds is the stronger statement that a full
  # fixture run does not even *attempt* one.
  describe "a complete fixture ingestion" do
    let(:transport) { fixture_transport }

    before { active_budget_window(now: frozen_time) }

    it "produces the documented counts with no HTTP request of any kind" do
      result = fixture_runner(transport: transport).call(event_source: fixture_event_source)

      expect(result).to be_completed
      expect(PushEvent.count).to eq(4)
      expect(GithubActor.count).to eq(3)
      expect(GithubRepository.count).to eq(3)
      expect(QuarantinedEvent.count).to eq(3)
      expect(a_request(:any, /.*/)).not_to have_been_made
    end

    it "spends the poll class of the local ledger and nothing else" do
      fixture_runner(transport: transport).call(event_source: fixture_event_source)

      expect(current_budget.poll_used).to eq(1)
      expect(current_budget.enrichment_used).to eq(0)
    end
  end
end
