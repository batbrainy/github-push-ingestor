require "rails_helper"

RSpec.describe Github::ResponseClassifier do
  def classify(status, headers = {})
    described_class.classify(status: status, headers: headers)
  end

  describe "success" do
    it "classifies a 200 as ok" do
      expect(classify(200)).to eq(:ok)
    end

    # §10: no event processing runs, and the reservation stays debited, because an
    # unauthenticated 304 consumes quota. The classification exists so the page loop skips
    # processing without anyone concluding the request was free.
    it "classifies a 304 as not modified, which is still a spent request" do
      expect(classify(304)).to eq(:not_modified)
    end

    it "treats both as successful, so a caller can branch once" do
      expect(described_class.successful?(:ok)).to be(true)
      expect(described_class.successful?(:not_modified)).to be(true)
      expect(described_class.successful?(:server_error)).to be(false)
    end
  end

  describe "rate limiting" do
    # §10's own discriminator: "403 or 429 with exhausted quota" is the primary limit;
    # anything else on those statuses is a secondary limit. The status alone cannot
    # tell them apart, and they have different remedies.
    it "classifies a 403 with no remaining quota as primary exhaustion" do
      expect(classify(403, "x-ratelimit-remaining" => "0")).to eq(:rate_limited)
    end

    it "classifies a 429 with no remaining quota identically" do
      expect(classify(429, "x-ratelimit-remaining" => "0")).to eq(:rate_limited)
    end

    # Deferring only the source would leave enrichment hammering the same IP, and
    # secondary limits are IP-scoped.
    it "classifies a 403 with quota remaining as a secondary limit" do
      expect(classify(403, "retry-after" => "60", "x-ratelimit-remaining" => "42"))
        .to eq(:secondary_limited)
    end

    it "classifies a 403 with no rate-limit headers as a secondary limit" do
      expect(classify(403)).to eq(:secondary_limited)
    end

    it "reads the remaining header case-insensitively" do
      expect(classify(403, "X-RateLimit-Remaining" => "0")).to eq(:rate_limited)
    end

    # §10: do not retry immediately — defer to the reset. Retrying would spend the
    # quota the deferral exists to protect.
    it "never marks either kind retryable" do
      expect(described_class.retryable?(:rate_limited)).to be(false)
      expect(described_class.retryable?(:secondary_limited)).to be(false)
    end
  end

  describe "permanent failures" do
    # §10: an actor or repository URL returning 404/410 is an entity outcome. The
    # event source stays enabled — one deleted repository must never disable /events.
    it "classifies 404 and 410 as a missing target, distinct from other client errors" do
      expect(classify(404)).to eq(:not_found)
      expect(classify(410)).to eq(:not_found)
    end

    it "classifies other 4xx as a client error" do
      expect(classify(400)).to eq(:client_error)
      expect(classify(422)).to eq(:client_error)
    end
  end

  describe "redirects" do
    it "classifies every redirect status the API can return" do
      described_class::REDIRECT_STATUSES.each do |status|
        expect(classify(status, "location" => "https://api.github.com/repos/o/renamed"))
          .to eq(:redirect), "expected #{status} with a Location to be a redirect"
      end
    end

    # A redirect with nowhere to go would loop the executor against a nil target.
    it "classifies a redirect without a Location as a client error, not a hop" do
      expect(classify(301)).to eq(:client_error)
    end

    it "never marks a redirect retryable, because the executor follows it instead" do
      expect(described_class.retryable?(:redirect)).to be(false)
    end
  end

  describe "transient failures" do
    it "classifies 5xx as a server error" do
      expect(classify(500)).to eq(:server_error)
      expect(classify(503)).to eq(:server_error)
    end

    # §10 lists exactly "5xx or network timeout" as retryable, and each retry
    # re-reserves one of sixty requests an hour. Nothing else earns one.
    it "makes the server error the only retryable classification" do
      retryable = described_class::CLASSIFICATIONS.select { |c| described_class.retryable?(c) }

      expect(retryable).to contain_exactly(:server_error)
    end
  end

  # Github::RateLimitPolicy's blocking rules and PR 7's entity state machine both branch on this
  # vocabulary. A silently added value would fall through their case statements.
  it "names a closed classification vocabulary" do
    expect(described_class::CLASSIFICATIONS).to match_array(
      %i[ ok not_modified redirect rate_limited secondary_limited not_found client_error server_error ]
    )
  end
end
