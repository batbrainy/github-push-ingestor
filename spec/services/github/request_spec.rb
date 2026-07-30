require "rails_helper"

RSpec.describe Github::Request do
  def request(**overrides)
    described_class.new(**{ url: "https://api.github.com/events", request_class: :poll }.merge(overrides))
  end

  describe "the request class" do
    # The class is what the ledger debits (§7) and what PR 5 and PR 7 use to tell a
    # source failure from an entity failure (§10). Inferring it anywhere would put two
    # answers in the system.
    it "is required, so no component ever has to infer which budget to debit" do
      expect { described_class.new(url: "https://api.github.com/events") }.to raise_error(ArgumentError)
    end

    it "accepts exactly the three classes the ledger has counters for" do
      described_class::CLASSES.each do |request_class|
        expect(request(request_class: request_class).request_class).to eq(request_class)
      end
    end

    it "rejects an unknown class rather than silently spending the wrong allowance" do
      expect { request(request_class: :search) }
        .to raise_error(ArgumentError, /request_class/)
    end

    it "treats actor and repository requests as enrichment, and polls as not" do
      expect(request(request_class: :actor)).to be_enrichment
      expect(request(request_class: :repository)).to be_enrichment
      expect(request(request_class: :poll)).not_to be_enrichment
    end
  end

  describe "the fairness borrow (plan §10)" do
    it "carries no borrow by default, so fairness binds unless a caller asks to spend past it" do
      expect(request(request_class: :actor).borrow).to be(false)
    end

    it "refuses a borrowing poll, because borrowing is a concept between the two enrichment classes" do
      expect { request(request_class: :poll, borrow: true) }
        .to raise_error(ArgumentError, /borrow/)
    end

    # The reason the flag rides on the request rather than on a RequestExecutor argument:
    # a redirect hop reserves again, and re-reserving a borrowed request under the
    # guarantee cap would deny mid-chain after the first hop was already spent.
    it "keeps the borrow across a redirect hop, which is reserved again under the same authorization" do
      hop = request(request_class: :actor, borrow: true)
              .redirected_to("https://api.github.com/users/octocat")

      expect(hop.borrow).to be(true)
    end

    it "logs the borrow only when there is one, so twelve poll lines an hour carry no false" do
      expect(request(request_class: :actor, borrow: true).to_log).to include(borrow: true)
      expect(request(request_class: :poll).to_log.keys).not_to include(:borrow)
    end
  end

  describe "protocol headers (plan §2A)" do
    it "sends the three headers GitHub requires on every request" do
      expect(request.headers).to include(
        "Accept" => "application/vnd.github+json",
        "X-GitHub-Api-Version" => "2022-11-28",
        "User-Agent" => "github-push-ingestor"
      )
    end

    # GitHub rejects requests without a valid User-Agent, and the pinned API version is
    # the one every live probe behind this plan was run under. A caller must not be
    # able to undo either by accident.
    it "cannot be overridden by a caller's own headers" do
      overriding = request(custom_headers: { "User-Agent" => "curl/8", "Accept" => "*/*" })

      expect(overriding.headers).to include(
        "User-Agent" => "github-push-ingestor",
        "Accept" => "application/vnd.github+json"
      )
    end

    it "keeps a caller's unrelated headers" do
      expect(request(custom_headers: { "X-Trace" => "abc" }).headers).to include("X-Trace" => "abc")
    end
  end

  describe "conditional requests" do
    it "sends no If-None-Match when the source has no stored ETag" do
      expect(request.headers).not_to have_key("If-None-Match")
    end

    it "sends the stored ETag when there is one" do
      expect(request(etag: 'W/"abc"').headers).to include("If-None-Match" => 'W/"abc"')
    end
  end

  describe "#redirected_to" do
    # A redirect hop is a separate outbound request to GitHub, so §7 debits it — and it
    # keeps the originating class, so a repository enrichment redirect stays a
    # repository request.
    it "keeps the originating request class, so the hop debits the same counter" do
      hop = request(request_class: :repository).redirected_to("https://api.github.com/repos/o/renamed")

      expect(hop.request_class).to eq(:repository)
      expect(hop.url).to eq("https://api.github.com/repos/o/renamed")
    end

    # The ETag was scoped to the original URL. Replaying it against a different
    # resource could produce a 304 for a document this application has never seen.
    it "drops the ETag, which was scoped to the URL that redirected" do
      expect(request(etag: 'W/"abc"').redirected_to("https://api.github.com/x").etag).to be_nil
    end
  end
end
