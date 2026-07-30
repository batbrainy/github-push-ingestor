require "rails_helper"

RSpec.describe Github::Transports::Fixture do
  # The redirecting_repository scenario inherits everything else from default, so one
  # transport can answer every question the shared contract asks, including the redirect.
  subject(:transport) { described_class.new(corpus: corpus(scenario: "redirecting_repository")) }

  let(:ok_url) { fixture_url("/events?per_page=100") }
  let(:other_mode_url) { live_url("/events?per_page=100") }
  let(:redirect_url) { fixture_url("/repos/octocat/Hello-World") }

  def sent_request_headers
    transport.requests.last.fetch(:headers)
  end

  it_behaves_like "a GitHub transport"

  describe "resolution" do
    it "serves the corpus body for a URL the corpus defines" do
      response = described_class.new(corpus: corpus).get(fixture_url("/users/octocat"))

      expect(JSON.parse(response.body)).to include("login" => "octocat", "name" => "The Octocat")
    end

    it "serves the corpus headers, which is what makes the ledger runnable offline" do
      response = described_class.new(corpus: corpus).get(ok_url)

      expect(response.headers).to include(
        "x-ratelimit-resource" => "core", "x-ratelimit-limit" => "60", "x-ratelimit-remaining" => "59"
      )
    end

    # §6: fixture mode fails closed. A miss is an authoring bug, and it must never be
    # answered by reaching the real API.
    it "raises for an unknown URL instead of falling back to the network" do
      expect { described_class.new(corpus: corpus).get(fixture_url("/users/nobody")) }
        .to raise_error(Github::Errors::FixtureMiss, %r{/users/nobody})
    end

    # RFC 3986 preserves the traversal, so a corpus that derived filenames from URLs
    # would read the file. Body paths are authored, so this is simply a miss.
    it "raises for a path-traversal URL rather than reading a file outside the corpus" do
      expect { described_class.new(corpus: corpus).get(fixture_url("/../../../../etc/passwd")) }
        .to raise_error(Github::Errors::FixtureMiss)
    end

    it "opens no socket at all" do
      described_class.new(corpus: corpus).get(ok_url)

      expect(WebMock).not_to have_requested(:any, //)
    end
  end

  describe "the rate-limit reset header" do
    # A fixed epoch in the corpus is in the past by the time anyone runs the demo, and
    # the ledger then correctly rolls the window on every poll — so counters never
    # accumulate and fixture mode stops demonstrating the accounting it exists to
    # demonstrate. Only this header shape is relative; bodies stay byte-static.
    it "resolves a relative reset against the clock, so the window is always current" do
      offline = described_class.new(corpus: corpus, clock: -> { frozen_time })

      expect(offline.get(ok_url).header("x-ratelimit-reset")).to eq((frozen_time + 3600).to_i.to_s)
    end

    it "leaves an absolute header value untouched" do
      offline = described_class.new(corpus: corpus, clock: -> { frozen_time })

      expect(offline.get(ok_url).header("x-ratelimit-limit")).to eq("60")
    end

    it "produces a snapshot the ledger can bootstrap a window from" do
      offline = described_class.new(corpus: corpus, clock: -> { frozen_time })
      snapshot = Github::RateLimitSnapshot.from_headers(offline.get(ok_url).headers, observed_at: frozen_time)

      expect(snapshot).to be_quantitative
      expect(snapshot.reset_at).to eq(frozen_time + 3600)
    end
  end

  describe "scripted sequences" do
    # §12's "304 with ETag" scenario. Positional scripting keeps it deterministic
    # without the corpus having to match on If-None-Match.
    it "serves scripted responses in order, so a 200 can be followed by a 304" do
      offline = described_class.new(corpus: corpus)

      expect(offline.get(ok_url).status).to eq(200)
      expect(offline.get(ok_url).status).to eq(304)
    end

    # Otherwise a long-running fixture container would start erroring after N polls.
    it "repeats the last scripted response forever" do
      offline = described_class.new(corpus: corpus)
      4.times { offline.get(ok_url) }

      expect(offline.get(ok_url).status).to eq(304)
    end

    # Class-level cursors would make one example's position depend on another's under
    # `config.order = :random`.
    it "keeps its cursor per instance, so one transport cannot advance another's script" do
      first = described_class.new(corpus: corpus)
      second = described_class.new(corpus: corpus)

      first.get(ok_url)

      expect(second.get(ok_url).status).to eq(200)
    end

    it "walks a multi-page scenario page by page" do
      offline = described_class.new(corpus: corpus(scenario: "paginated"))

      expect(offline.get(fixture_url("/events?per_page=100")).header("link")).to include("page=2")
      expect(JSON.parse(offline.get(fixture_url("/events?page=2&per_page=100")).body).size).to eq(3)
      expect(JSON.parse(offline.get(fixture_url("/events?page=3&per_page=100")).body)).to be_empty
    end
  end

  describe "recorded requests" do
    # How the conditional-request path is asserted without the corpus matching on
    # If-None-Match: the question worth answering is what was sent, not what came back.
    it "records every request with the headers it was given" do
      offline = described_class.new(corpus: corpus)

      offline.get(ok_url, headers: { "If-None-Match" => 'W/"abc"' })

      expect(offline.requests.last).to include(key: "/events?per_page=100")
      expect(offline.requests.last[:headers]).to include("if-none-match" => 'W/"abc"')
    end

    # Otherwise a protocol-header assertion would pass offline and fail against the API.
    it "carries the same pinned protocol headers as the live transport" do
      offline = described_class.new(corpus: corpus)
      offline.get(ok_url)

      expect(offline.requests.last[:headers]).to include(
        "accept" => "application/vnd.github+json",
        "x-github-api-version" => "2022-11-28",
        "user-agent" => "github-push-ingestor"
      )
    end
  end
end
