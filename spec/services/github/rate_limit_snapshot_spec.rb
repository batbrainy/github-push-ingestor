require "rails_helper"

RSpec.describe Github::RateLimitSnapshot do
  # A live response shape, from the transcripts behind plan §10.
  def headers(**overrides)
    {
      "x-ratelimit-limit" => "60",
      "x-ratelimit-remaining" => "55",
      "x-ratelimit-used" => "5",
      "x-ratelimit-reset" => "1785325920",
      "x-ratelimit-resource" => "core",
      "x-poll-interval" => "60",
      "etag" => 'W/"3f2a1c9d"'
    }.merge(overrides.transform_keys(&:to_s))
  end

  def snapshot(**overrides)
    described_class.from_headers(headers(**overrides), observed_at: frozen_time)
  end

  describe "the headers plan §10 processes" do
    it "parses every one of them" do
      expect(snapshot).to have_attributes(
        resource: "core",
        limit: 60,
        remaining: 55,
        used: 5,
        reset_at: Time.zone.at(1_785_325_920),
        poll_interval_seconds: 60,
        etag: 'W/"3f2a1c9d"',
        observed_at: frozen_time
      )
    end

    # Header names are case-insensitive in HTTP, and a mis-cased match here would
    # silently drop the ledger's only authoritative input.
    it "reads header names case-insensitively" do
      cased = described_class.from_headers({ "X-RateLimit-Remaining" => "42" }, observed_at: frozen_time)

      expect(cased.remaining).to eq(42)
    end

    it "converts the reset header from epoch seconds to a time" do
      expect(snapshot("x-ratelimit-reset" => "1785329520").reset_at).to eq(Time.zone.at(1_785_329_520))
    end

    it "parses Retry-After, which the rate-limit policy turns into a global block" do
      expect(snapshot("retry-after" => "60").retry_after_seconds).to eq(60)
    end
  end

  describe "tolerance" do
    # A rate-limit header this application cannot read must never be the reason a
    # successful response is discarded. Every unreadable value becomes nil, and the
    # ledger's monotonic reconciliation simply has nothing to apply.
    it "reports an unparseable value as absent rather than raising" do
      expect(snapshot("x-ratelimit-remaining" => "unknown").remaining).to be_nil
    end

    it "reports a blank value as absent" do
      expect(snapshot("x-ratelimit-resource" => "   ").resource).to be_nil
    end

    it "handles a response with no rate-limit headers at all" do
      expect { described_class.from_headers({}, observed_at: frozen_time) }.not_to raise_error
    end

    it "handles nil headers, as a transport failure with no response produces" do
      expect(described_class.from_headers(nil, observed_at: frozen_time).limit).to be_nil
    end
  end

  # RFC 9110 permits delta-seconds and an HTTP-date, and §10 lists Retry-After among the
  # headers to process without qualifying which form. Both are normalized to a delta here
  # so Github::RateLimitPolicy has one thing to reason about.
  describe "Retry-After" do
    def retry_after(value) = snapshot("retry-after" => value).retry_after_seconds

    it "reads the delta-seconds form GitHub actually sends" do
      expect(retry_after("120")).to eq(120)
    end

    # Resolved against the snapshot's own observed_at rather than the wall clock, so the
    # same headers always produce the same delta.
    it "converts the HTTP-date form to a delta against the observation instant" do
      expect(retry_after((frozen_time + 2700).httpdate)).to eq(2700)
    end

    # Not normalized to nil: this class reads and never decides, and the policy already
    # treats a non-positive delta exactly as it treats an absent header.
    it "reports a date that has already passed as a non-positive delta" do
      expect(retry_after((frozen_time - 300).httpdate)).to eq(-300)
    end

    it "reports a value that is neither form as absent" do
      expect(retry_after("immediately")).to be_nil
    end

    it "reports an absent header as absent" do
      expect(retry_after(nil)).to be_nil
    end
  end

  describe "#quantitative?" do
    # What the ledger needs before it can initialize or reconcile a window: without a
    # reset boundary there is no window to reconcile within.
    it "is true when limit, remaining, and reset are all present" do
      expect(snapshot).to be_quantitative
    end

    it "is false when the reset boundary is missing" do
      expect(snapshot("x-ratelimit-reset" => nil)).not_to be_quantitative
    end

    it "is false for an error page carrying no rate-limit headers" do
      expect(described_class.from_headers({}, observed_at: frozen_time)).not_to be_quantitative
    end
  end

  it "reports primary exhaustion, which §10 defers to the reset rather than retrying" do
    expect(snapshot("x-ratelimit-remaining" => "0")).to be_exhausted
    expect(snapshot("x-ratelimit-remaining" => "1")).not_to be_exhausted
  end
end
