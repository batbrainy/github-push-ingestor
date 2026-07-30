require "rails_helper"

RSpec.describe Github::RequestExecutor do
  # A transport that records the state of the world at the moment it is called, which is
  # how the ordering guarantees below are asserted rather than assumed. Anonymous so it
  # leaks no constant into the suite.
  let(:transport_class) do
    Class.new do
      attr_reader :calls

      def initialize(&responder)
        @responder = responder
        @calls = []
      end

      def get(validated_url, headers: {})
        @calls << {
          url: validated_url.to_s,
          headers: headers,
          gate_held: Github::RequestGate.held?,
          poll_used: GithubApiBudget.find_by(id: GithubApiBudget::SINGLETON_ID)&.poll_used
        }
        @responder.call(@calls.size, validated_url)
      end
    end
  end

  def recording_transport(&responder)
    transport_class.new(&responder)
  end

  def response(status:, headers: {}, body: "[]", url: nil)
    Github::Transports::Response.new(
      status: status, headers: Github::Transports::Response.normalize(headers),
      body: body, url: url, duration_ms: 1.0
    )
  end

  def rate_limit_headers(remaining: 59, used: 1)
    {
      "x-ratelimit-resource" => "core", "x-ratelimit-limit" => "60",
      "x-ratelimit-remaining" => remaining.to_s, "x-ratelimit-used" => used.to_s,
      "x-ratelimit-reset" => (frozen_time + 3600).to_i.to_s
    }
  end

  def executor(transport, **overrides)
    described_class.new(
      transport: transport,
      retry_policy: Github::RetryPolicy.new(max_attempts: 2, random: Random.new(7)),
      mode: :live,
      max_redirects: 2,
      sleeper: overrides.fetch(:sleeper, ->(_seconds) { }),
      clock: -> { frozen_time },
      **overrides.except(:sleeper)
    )
  end

  # per_page=100 is part of the canonical first-page URL, so the same request resolves
  # in the corpus as well as under WebMock.
  let(:poll_request) do
    Github::Request.new(url: "https://api.github.com/events?per_page=100", request_class: :poll)
  end

  describe "the chain" do
    # §2A: acquire gate -> reserve -> perform exactly one request -> reconcile -> release.
    it "holds the gate and has already debited the budget when the transport is called" do
      active_budget_window
      transport = recording_transport { response(status: 200, headers: rate_limit_headers) }

      executor(transport).call(poll_request)

      expect(transport.calls.size).to eq(1)
      expect(transport.calls.first).to include(gate_held: true, poll_used: 1)
    end

    it "returns a classified result rather than a raw response" do
      active_budget_window
      transport = recording_transport { response(status: 200, headers: rate_limit_headers) }

      result = executor(transport).call(poll_request)

      expect(result).to be_ok
      expect(result.body).to eq("[]")
    end

    it "reconciles the response's rate-limit headers before releasing the gate" do
      active_budget_window(remaining: 59)
      transport = recording_transport { response(status: 200, headers: rate_limit_headers(remaining: 42)) }

      executor(transport).call(poll_request)

      expect(current_budget.remaining).to eq(42)
    end

    it "sends the pinned protocol headers with every request" do
      active_budget_window
      transport = recording_transport { response(status: 200, headers: rate_limit_headers) }

      executor(transport).call(poll_request)

      expect(transport.calls.first[:headers]).to include("User-Agent" => "github-push-ingestor")
    end

    it "releases the gate after the request, so the next caller is not blocked" do
      active_budget_window
      transport = recording_transport { response(status: 200, headers: rate_limit_headers) }

      executor(transport).call(poll_request)

      expect(Github::RequestGate).not_to be_held
    end

    it "releases the gate even when the transport raises" do
      active_budget_window
      transport = recording_transport { raise Github::Errors::ConnectionFailed, "refused" }

      executor(transport).call(poll_request)

      expect(Github::RequestGate).not_to be_held
    end

    # §5, Appendix D item 1: enrichment requests belong to no event source, so the chain
    # is identical for both paths and never touches a source lock. LockOrder would raise
    # if it did, since the gate is held by then.
    it "acquires no source lock, because enrichment requests belong to no source" do
      active_budget_window
      transport = recording_transport do
        expect { Github::SourceLock.acquire(1) { nil } }.to raise_error(Github::Errors::LockOrderViolation)
        response(status: 200, headers: rate_limit_headers)
      end

      expect(executor(transport).call(poll_request)).to be_ok
    end
  end

  describe "retries (plan §10)" do
    # "Retry up to MAX_HTTP_RETRIES through the same gate and ledger — each attempt is a
    # reservation." Collapsing that to one debit per logical fetch would silently
    # under-count real requests GitHub has already charged for.
    it "reserves budget again for every retry attempt" do
      active_budget_window
      transport = recording_transport do |call|
        call < 3 ? response(status: 500, headers: rate_limit_headers) : response(status: 200, headers: rate_limit_headers)
      end

      executor(transport).call(poll_request)

      expect(transport.calls.map { |c| c[:poll_used] }).to eq([ 1, 2, 3 ])
    end

    it "stops after MAX_HTTP_RETRIES and returns the last failure" do
      active_budget_window
      transport = recording_transport { response(status: 500, headers: rate_limit_headers) }

      result = executor(transport).call(poll_request)

      expect(transport.calls.size).to eq(3)
      expect(result.classification).to eq(:server_error)
      expect(result.attempt).to eq(2)
    end

    # Holding the global serial gate across a backoff sleep would stall every other
    # process in the application for the duration of that sleep.
    it "releases the gate before backing off" do
      active_budget_window
      held_while_sleeping = []
      transport = recording_transport { response(status: 500, headers: rate_limit_headers) }

      executor(transport, sleeper: ->(_s) { held_while_sleeping << Github::RequestGate.held? })
        .call(poll_request)

      expect(held_while_sleeping).to eq([ false, false ])
    end

    it "does not retry a classification the policy calls terminal" do
      active_budget_window
      transport = recording_transport { response(status: 404, headers: rate_limit_headers) }

      executor(transport).call(poll_request)

      expect(transport.calls.size).to eq(1)
    end

    it "retries a network-level failure and can still succeed" do
      active_budget_window
      transport = recording_transport do |call|
        raise Github::Errors::RequestTimeout, "timed out" if call == 1

        response(status: 200, headers: rate_limit_headers)
      end

      expect(executor(transport).call(poll_request)).to be_ok
      expect(transport.calls.size).to eq(2)
    end
  end

  describe "redirects (plan §10)" do
    let(:repository_request) do
      Github::Request.new(url: "https://api.github.com/repos/octocat/Hello-World", request_class: :repository)
    end

    it "follows a redirect to a target the policy accepts" do
      active_budget_window
      transport = recording_transport do |call|
        if call == 1
          response(status: 301, headers: rate_limit_headers.merge(
            "location" => "https://api.github.com/repos/octocat/renamed"
          ))
        else
          response(status: 200, headers: rate_limit_headers, body: "{}")
        end
      end

      result = executor(transport).call(repository_request)

      expect(result).to be_ok
      expect(transport.calls.last[:url]).to eq("https://api.github.com/repos/octocat/renamed")
    end

    # §7: every actual outbound attempt debits its class counter, and a redirect hop is
    # a real outbound request.
    it "reserves budget for each hop, against the originating request's class" do
      active_budget_window
      transport = recording_transport do |call|
        if call == 1
          response(status: 301, headers: rate_limit_headers.merge(
            "location" => "https://api.github.com/repos/octocat/renamed"
          ))
        else
          response(status: 200, headers: rate_limit_headers, body: "{}")
        end
      end

      executor(transport).call(repository_request)

      expect(current_budget)
        .to have_attributes(enrichment_used: 2, repository_share_used: 2, actor_share_used: 0, poll_used: 0)
    end

    # The whole reason redirects are not delegated to Faraday middleware.
    it "refuses a redirect that leaves the allowed host" do
      active_budget_window
      transport = recording_transport do
        response(status: 301, headers: rate_limit_headers.merge("location" => "https://evil.test/repos/x"))
      end

      result = executor(transport).call(repository_request)

      expect(result.classification).to eq(:permanent_error)
      expect(result.error).to be_a(Github::Errors::UrlPolicyViolation)
      expect(transport.calls.size).to eq(1)
    end

    it "stops after MAX_REDIRECTS rather than looping" do
      active_budget_window
      transport = recording_transport do |call|
        response(status: 301, headers: rate_limit_headers.merge(
          "location" => "https://api.github.com/repos/octocat/hop-#{call}"
        ))
      end

      result = executor(transport).call(repository_request)

      expect(result.error).to be_a(Github::Errors::RedirectLimitExceeded)
      expect(transport.calls.size).to eq(3)
    end
  end

  describe "outcomes that spend nothing" do
    it "never calls the transport when the ledger denies the reservation" do
      active_budget_window(poll_used: 12)
      transport = recording_transport { response(status: 200) }

      result = executor(transport).call(poll_request)

      expect(transport.calls).to be_empty
      expect(result.classification).to eq(:budget_denied)
      expect(result).to be_deferred
    end

    # §10's boundary is never crossed, and §7's "failures stay spent" is about outbound
    # attempts — a URL that was never sent must not cost a request.
    it "never calls the transport, and debits nothing, when the URL policy refuses" do
      active_budget_window
      transport = recording_transport { response(status: 200) }
      hostile = Github::Request.new(url: "https://evil.test/users/root", request_class: :actor)

      result = executor(transport).call(hostile)

      expect(transport.calls).to be_empty
      expect(current_budget.enrichment_used).to eq(0)
      expect(result.error).to be_a(Github::Errors::UrlPolicyViolation)
    end

    it "reports a busy gate as a deferral rather than a failure" do
      active_budget_window
      transport = recording_transport { response(status: 200) }
      namespace = Github::AdvisoryLock::REQUEST_GATE_NAMESPACE

      result = other_session_holding(namespace, Github::AdvisoryLock::REQUEST_GATE_KEY) do
        executor(transport, request_gate_wait: 0.1).call(poll_request)
      end

      expect(result.classification).to eq(:gate_unavailable)
      expect(result).to be_deferred
      expect(transport.calls).to be_empty
    end
  end

  describe "failures stay spent (plan §7)" do
    it "keeps every attempt's debit when the transport fails without a response" do
      active_budget_window
      transport = recording_transport { raise Github::Errors::ConnectionFailed, "refused" }

      result = executor(transport).call(poll_request)

      expect(current_budget.poll_used).to eq(3)
      expect(result.classification).to eq(:transport_error)
    end

    # §10's corrected accounting: an unauthenticated 304 consumes quota.
    it "keeps the debit for a 304" do
      active_budget_window
      transport = recording_transport { response(status: 304, headers: rate_limit_headers, body: "") }

      result = executor(transport).call(poll_request)

      expect(result).to be_not_modified
      expect(current_budget.poll_used).to eq(1)
    end
  end

  describe "fixture mode" do
    # §6: "if a URL is not present in the corpus, a fixture error is raised". A corpus
    # gap is an authoring bug, not a runtime outcome — laundering it into a failed fetch
    # would let a fixture-mode demo report a plausible-looking failure rather than
    # naming the missing entry.
    it "raises a corpus gap instead of reporting it as a failed fetch" do
      active_budget_window
      offline = Github::Transports::Fixture.new(corpus: corpus)

      expect {
        executor(offline, mode: :fixture).call(
          Github::Request.new(url: "https://api.github.com/users/nobody",
                              request_class: :actor, origin: :payload)
        )
      }.to raise_error(Github::Errors::FixtureMiss)
    end

    it "runs the same chain offline, spending the ledger against corpus headers" do
      active_budget_window(remaining: 60)
      offline = Github::Transports::Fixture.new(corpus: corpus)

      # The offline source's own fixture:// location: application-origin, so it is
      # validated against fixture mode directly rather than through the payload path.
      result = executor(offline, mode: :fixture).call(
        Github::EventSources::FixtureEvents.new.first_page_request
      )

      expect(result).to be_ok
      expect(current_budget).to have_attributes(poll_used: 1, remaining: 59)
    end
  end
end
