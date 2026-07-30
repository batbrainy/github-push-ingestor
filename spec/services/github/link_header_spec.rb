require "rails_helper"

RSpec.describe Github::LinkHeader do
  # The shape GitHub actually sends on /events, taken from the fixture corpus.
  let(:github_header) do
    '<https://api.github.com/events?per_page=100&page=2>; rel="next", ' \
      '<https://api.github.com/events?per_page=100&page=3>; rel="last"'
  end

  describe ".next_url" do
    it "follows rel=next" do
      expect(described_class.next_url(github_header))
        .to eq("https://api.github.com/events?per_page=100&page=2")
    end

    # The defect this exists to catch: page one's rel="last" points at page three, so an
    # implementation that took the first bracketed URL it saw, or preferred "last", would
    # skip every page in between and still look like it worked.
    it "ignores rel=last, which on page one points past the page we want" do
      expect(described_class.next_url(github_header)).not_to include("page=3")
    end

    it "reads an unquoted rel, which RFC 8288 permits" do
      expect(described_class.next_url("<https://api.github.com/events?page=2>; rel=next"))
        .to eq("https://api.github.com/events?page=2")
    end

    it "reads a rel carrying several space-separated relation types" do
      header = '<https://api.github.com/events?page=9>; rel="next last"'

      expect(described_class.next_url(header)).to eq("https://api.github.com/events?page=9")
      expect(described_class.parse(header)).to eq(
        "next" => "https://api.github.com/events?page=9",
        "last" => "https://api.github.com/events?page=9"
      )
    end

    it "matches the parameter name case-insensitively and downcases the relation" do
      expect(described_class.next_url('<https://api.github.com/events>; REL="NEXT"'))
        .to eq("https://api.github.com/events")
    end

    it "returns nil for a header that offers only earlier pages" do
      header = '<https://api.github.com/events?page=1>; rel="first", ' \
               '<https://api.github.com/events?page=1>; rel="prev"'

      expect(described_class.next_url(header)).to be_nil
    end

    # Every one of these means the same thing to the page loop — there is no next page —
    # and none of them may raise: a run that has already persisted events must not fail
    # because GitHub sent a header this parser cannot read.
    it "treats an absent, blank, or unreadable header as no next page" do
      [ nil, "", "   ", "garbage", "<unterminated; rel=\"next\"", "rel=\"next\"" ].each do |value|
        expect { described_class.next_url(value) }.not_to raise_error
        expect(described_class.next_url(value)).to be_nil
      end
    end
  end

  describe ".parse" do
    it "keeps the first occurrence of a relation" do
      header = '<https://api.github.com/a>; rel="next", <https://api.github.com/b>; rel="next"'

      expect(described_class.parse(header)).to eq("next" => "https://api.github.com/a")
    end

    # A quoted parameter value may contain the very characters that separate link-values,
    # which is why the scanner is a regex over the whole header rather than a split on ",".
    it "survives a comma and a semicolon inside a quoted parameter" do
      header = '<https://api.github.com/events?page=2>; title="a, b; c"; rel="next"'

      expect(described_class.parse(header)).to include("next" => "https://api.github.com/events?page=2")
    end

    it "ignores parameters it does not understand" do
      header = '<https://api.github.com/events?page=2>; type="application/json"; rel="next"'

      expect(described_class.parse(header)).to eq("next" => "https://api.github.com/events?page=2")
    end

    # The target is evidence, not a decision. Github::EventSources::Base marks it
    # payload-supplied so Github::UrlPolicy re-parses it under the full live policy before
    # anything opens a socket; normalising it here would mean this module deciding what a
    # safe URL looks like in a second place.
    it "returns the target verbatim, including a host the URL policy will reject" do
      header = '<https://evil.example.com/events?page=2>; rel="next"'

      expect(described_class.parse(header)).to eq("next" => "https://evil.example.com/events?page=2")
    end

    it "skips a link-value with an empty target" do
      expect(described_class.parse('<>; rel="next"')).to eq({})
    end
  end
end
