require "rails_helper"

RSpec.describe Github::FetchResult do
  let(:request) { Github::Request.new(url: "https://api.github.com/events", request_class: :poll) }

  def result(status: 200, headers: {}, body: "[]")
    described_class.from_response(request: request, status: status, headers: headers,
                                  body: body, duration_ms: 12.5)
  end

  describe ".from_response" do
    it "classifies the response so a caller never has to read the status itself" do
      expect(result(status: 304).classification).to eq(:not_modified)
    end

    # Callers read headers by a single spelling, and GitHub is not consistent about
    # casing across responses.
    it "downcases header names, so the ledger cannot miss a differently-cased header" do
      expect(result(headers: { "X-RateLimit-Remaining" => "59" }).header("x-ratelimit-remaining"))
        .to eq("59")
    end

    # §7 retains the raw payload, and PR 5's malformed-event taxonomy has to tell "this
    # body is not JSON" apart from "this event is malformed". Parsing here would erase
    # the difference.
    it "leaves the body exactly as received, unparsed" do
      expect(result(body: '{"not":"parsed"}').body).to eq('{"not":"parsed"}')
    end

    it "exposes the ETag and Location a caller needs by name" do
      fetched = result(headers: { "etag" => 'W/"abc"', "location" => "https://api.github.com/x" })

      expect(fetched.etag).to eq('W/"abc"')
      expect(fetched.location).to eq("https://api.github.com/x")
    end

    # PR 6 parses Link into next/last. PR 4 only guarantees the raw value survives.
    it "carries the raw Link header through without parsing it" do
      link = '<https://api.github.com/events?page=2>; rel="next"'

      expect(result(headers: { "link" => link }).link_header).to eq(link)
    end

    it "builds a rate-limit snapshot from its own headers" do
      fetched = result(headers: { "x-ratelimit-remaining" => "59", "x-ratelimit-limit" => "60" })

      expect(fetched.rate_limit(observed_at: frozen_time))
        .to have_attributes(remaining: 59, limit: 60, observed_at: frozen_time)
    end
  end

  describe ".from_error" do
    it "carries the failure without a status, because none was obtained" do
      error = Github::Errors::RequestTimeout.new("read timed out")

      failed = described_class.from_error(request: request, error: error, classification: :transport_error)

      expect(failed).to have_attributes(status: nil, body: nil, error: error, classification: :transport_error)
    end

    it "still answers header lookups, so callers need no nil checks" do
      failed = described_class.from_error(request: request, error: StandardError.new,
                                          classification: :permanent_error)

      expect(failed.etag).to be_nil
    end
  end

  describe "the outcome vocabulary" do
    # #call has one return type on purpose: a caller that must rescue four exception
    # classes to poll a page will eventually miss one.
    it "covers every response classification plus the outcomes that produced no status" do
      expect(described_class::CLASSIFICATIONS)
        .to match_array(Github::ResponseClassifier::CLASSIFICATIONS + described_class::NON_HTTP_CLASSIFICATIONS)
    end

    # A busy gate and a refused reservation mean the request never happened, so a
    # caller reschedules rather than recording a failure against a healthy source.
    it "separates deferrals from failures" do
      expect(described_class::DEFERRED_CLASSIFICATIONS).to contain_exactly(:budget_denied, :gate_unavailable)

      deferred = described_class.from_error(request: request, error: Github::Errors::GateUnavailable.new,
                                            classification: :gate_unavailable)

      expect(deferred).to be_deferred
      expect(result).not_to be_deferred
    end
  end

  describe "#to_log" do
    # §11 pins the common log fields; the JSON formatter merges a hash into the root,
    # so this is what a request line actually looks like.
    it "carries the request context, status, and timing for the structured log" do
      expect(result.to_log).to include(
        request_class: :poll, http_method: :get, url: "https://api.github.com/events",
        http_status: 200, classification: :ok, duration_ms: 12.5
      )
    end

    it "omits error fields when nothing failed" do
      expect(result.to_log.keys).not_to include(:error_class, :error_message)
    end
  end
end
