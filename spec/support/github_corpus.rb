# One corpus, three consumers (IMPLEMENTATION_PLAN.md §12). These helpers are what make
# the third one real: stub_corpus! turns manifest entries into WebMock stubs, so unit
# specs exercise the live Faraday transport against the exact bytes the offline transport
# serves.
#
# WebMock's multi-value to_return is sequential with a repeating last element, which is
# already the corpus's sticky-tail rule — so the two consumers cannot drift.
module GithubCorpus
  def corpus(scenario: "default")
    Github::FixtureCorpus.load(root: Rails.root.join("fixtures", "github"), scenario: scenario)
  end

  def stub_corpus!(scenario: "default")
    corpus(scenario: scenario).responses.each do |key, scripted|
      stub_request(:get, "https://api.github.com#{key}")
        .to_return(scripted.map { |r| { status: r.status, headers: r.headers, body: r.body } })
    end
  end

  def live_url(path_and_query)
    Github::UrlPolicy.validate!("https://api.github.com#{path_and_query}", mode: :live)
  end

  def fixture_url(path_and_query)
    Github::UrlPolicy.validate!("fixture://api.github.com#{path_and_query}", mode: :fixture)
  end
end

RSpec.configure do |config|
  config.include GithubCorpus

  # The corpus is cached per (root, scenario) for the life of the process, and the cache
  # is keyed on immutable inputs — but a spec that builds a throwaway corpus in a tmpdir
  # would otherwise leave it behind for the rest of a random-ordered run.
  config.after { Github::FixtureCorpus.reset! }
end
