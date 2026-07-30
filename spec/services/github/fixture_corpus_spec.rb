require "rails_helper"

RSpec.describe Github::FixtureCorpus do
  describe ".canonical_key" do
    # One entry has to answer a request from either transport, so the key omits scheme
    # and host — Github::UrlPolicy has already proved both.
    it "derives the same key from a live URL and its fixture projection" do
      live = live_url("/users/octocat")
      fixture = Github::UrlPolicy.validate_payload_url!(live.to_s, mode: :fixture)

      expect(described_class.key_for(fixture)).to eq(described_class.key_for(live))
    end

    # Otherwise a Link header spelling its parameters in a different order would miss an
    # entry the corpus genuinely defines.
    it "sorts query parameters, so parameter order cannot cause a miss" do
      expect(described_class.key_for(live_url("/events?per_page=100&page=2")))
        .to eq(described_class.key_for(live_url("/events?page=2&per_page=100")))
    end

    it "keys a URL with no query by its path alone" do
      expect(described_class.key_for(live_url("/users/octocat"))).to eq("/users/octocat")
    end
  end

  describe "loading" do
    it "resolves the scenarios the suite and the reviewer path name" do
      expect(corpus.scenario_names).to include(
        "default", "paginated", "rate_limited", "secondary_rate_limited",
        "transient_failure", "transient_failure_exhausted", "redirecting_repository", "hostile_redirect"
      )
    end

    it "inherits unnamed keys from the default scenario" do
      expect(corpus(scenario: "rate_limited").responses_for("/users/octocat")).to be_present
    end

    it "overrides the keys a scenario names" do
      expect(corpus(scenario: "rate_limited").responses_for("/events?per_page=100").first.status).to eq(403)
    end

    it "merges the manifest's default headers into every response" do
      response = corpus.responses_for("/events?per_page=100").first

      expect(response.headers).to include("x-ratelimit-resource" => "core", "x-ratelimit-limit" => "60")
    end

    it "lets a response override an inherited default header" do
      response = corpus(scenario: "rate_limited").responses_for("/events?per_page=100").first

      expect(response.headers["x-ratelimit-remaining"]).to eq("0")
    end

    it "reports an unknown scenario rather than silently serving the default" do
      expect { corpus(scenario: "nonexistent") }
        .to raise_error(Github::Errors::FixtureCorpusError, /no "nonexistent" scenario/)
    end
  end

  describe "corpus integrity" do
    # Without these, a fixture-mode run would silently 404 every actor or repository and
    # the failure would look like an enrichment bug rather than a corpus gap.
    it "resolves every actor URL that appears in any event page" do
      expect(unresolved_payload_urls("actor")).to be_empty
    end

    it "resolves every repository URL that appears in any event page" do
      expect(unresolved_payload_urls("repo")).to be_empty
    end

    # A dangling next page would end a pagination test early for the wrong reason.
    it "resolves every Link header target it publishes" do
      unresolved = corpus(scenario: "paginated").responses.flat_map do |_key, scripted|
        scripted.flat_map { |response| link_targets(response.headers["link"]) }
      end.reject { |target| corpus(scenario: "paginated").responses_for(key_of(target)) }

      expect(unresolved).to be_empty
    end

    # A database written in fixture mode has to be indistinguishable from one written
    # live, so no body may contain a fixture-only address.
    it "publishes only real api.github.com URLs inside event bodies" do
      urls = event_pages.flat_map { |page| page.flat_map { |event| collect_urls(event) } }

      expect(urls).to all(start_with("https://api.github.com/"))
      expect(urls).not_to be_empty
    end

    it "parses every body file as JSON" do
      body_files.each do |path|
        expect { JSON.parse(path.read) }.not_to raise_error, "expected #{path} to be valid JSON"
      end
    end

    it "leaves no orphan body file that no scenario serves" do
      served = all_scenarios.flat_map { |name| corpus(scenario: name).responses.values }
        .flatten.map(&:body).reject(&:empty?).to_set

      orphans = body_files.reject { |path| served.include?(path.read) }

      expect(orphans).to be_empty, "unused body files: #{orphans.map(&:basename).join(", ")}"
    end

    # The post-2025-10-07 payload shape the plan pins. If the corpus drifts from it,
    # PR 5's parser tests stop meaning anything.
    it "gives every PushEvent exactly the five documented payload fields and no commits" do
      push_payloads = event_pages.flatten.select { |event| event["type"] == "PushEvent" }.map { |e| e["payload"] }

      expect(push_payloads).not_to be_empty
      push_payloads.each do |payload|
        expect(payload.keys - %w[ repository_id push_id ref head before pusher_type ]).to be_empty
        expect(payload).not_to have_key("commits")
      end
    end
  end

  describe "the body path boundary" do
    # fixture://api.github.com/../../etc/passwd parses with its path preserved, so a
    # corpus that derived filenames from URLs would read it. Body paths are authored,
    # and a manifest that tried to escape is refused outright.
    it "refuses a manifest whose body path escapes the corpus directory" do
      Dir.mktmpdir do |dir|
        write_corpus(dir, "/x" => "../../../../etc/passwd")

        expect { described_class.new(root: dir) }
          .to raise_error(Github::Errors::FixtureCorpusError, /escapes/)
      end
    end

    it "refuses a manifest naming a body file that does not exist" do
      Dir.mktmpdir do |dir|
        write_corpus(dir, "/x" => "events/missing.json")

        expect { described_class.new(root: dir) }
          .to raise_error(Github::Errors::FixtureCorpusError, /no fixture body/)
      end
    end

    it "refuses a corpus directory with no manifest" do
      Dir.mktmpdir do |dir|
        expect { described_class.new(root: dir) }
          .to raise_error(Github::Errors::FixtureCorpusError, /no fixture manifest/)
      end
    end

    it "refuses a manifest that is not valid JSON" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "manifest.json"), "{ not json")

        expect { described_class.new(root: dir) }
          .to raise_error(Github::Errors::FixtureCorpusError, /not valid JSON/)
      end
    end

    it "refuses a manifest written against a different corpus version" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "manifest.json"),
                   JSON.generate(version: 99, scenarios: { "default" => { "responses" => {} } }))

        expect { described_class.new(root: dir) }
          .to raise_error(Github::Errors::FixtureCorpusError, /version/)
      end
    end
  end

  def all_scenarios
    corpus.scenario_names
  end

  def body_files
    Rails.root.glob("fixtures/github/bodies/**/*.json")
  end

  def event_pages
    Rails.root.glob("fixtures/github/bodies/events/*.json").map { |path| JSON.parse(path.read) }
  end

  def collect_urls(event)
    [ event.dig("actor", "url"), event.dig("repo", "url") ].compact
  end

  def unresolved_payload_urls(section)
    event_pages.flatten.filter_map { |event| event.dig(section, "url") }.uniq.reject do |url|
      corpus.responses_for(key_of(url))
    end
  end

  def key_of(url)
    described_class.key_for(Github::UrlPolicy.validate!(url, mode: :live))
  end

  def link_targets(header)
    header.to_s.scan(/<([^>]+)>/).flatten
  end

  def write_corpus(dir, responses)
    manifest = {
      version: 1,
      scenarios: {
        "default" => {
          "responses" => responses.transform_values { |body| [ { "status" => 200, "body" => body } ] }
        }
      }
    }
    File.write(File.join(dir, "manifest.json"), JSON.generate(manifest))
  end
end
