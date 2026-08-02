require "rails_helper"

# The bounded exception path: one core request against the api_url the event payload
# supplied, never a URL built from a login or name. Executor calls are recorded, so
# the URL discipline and the borrow flag are asserted from what was actually sent.
RSpec.describe Github::Enrichment::DetailRunner do
  let(:now) { frozen_time }
  let(:configuration) { Github.configuration }

  let(:executor_class) do
    Class.new do
      attr_reader :requests

      def initialize(&responder)
        @responder = responder
        @requests = []
      end

      def call(request)
        @requests << request
        @responder.call(request, @requests.length)
      end
    end
  end

  def recording_executor(&responder)
    executor_class.new(&responder)
  end

  def runner(executor, now: frozen_time)
    described_class.new(
      executor: executor, configuration: configuration,
      claim: Github::Enrichment::DetailClaim.new(configuration: configuration),
      backoff: jitterless_backoff(configuration: configuration),
      clock: -> { now }
    )
  end

  def core_headers(remaining: 55, used: 5)
    { "x-ratelimit-resource" => "core", "x-ratelimit-limit" => "60",
      "x-ratelimit-remaining" => remaining.to_s, "x-ratelimit-used" => used.to_s,
      "x-ratelimit-reset" => (frozen_time + 3600).to_i.to_s }
  end

  def detail_success(request, body:)
    Github::FetchResult.from_response(request: request, status: 200,
                                      headers: core_headers, body: body, duration_ms: 1.0)
  end

  def transport_failure(request)
    Github::FetchResult.from_error(request: request,
                                   error: Github::Errors::ConnectionFailed.new("connection refused"),
                                   classification: :transport_error)
  end

  def actor_body(github_id:, login: "octocat")
    JSON.generate("id" => github_id, "login" => login, "type" => "User")
  end

  def fallback_actor(github_id:, detail_pending_at: now - 60, **overrides)
    create_actor(github_id: github_id, login: "user-#{github_id}",
                 api_url: "https://api.github.com/users/user-#{github_id}",
                 enrichment_stage: "detail_pending",
                 detail_pending_at: detail_pending_at, **overrides)
  end

  describe "the request it sends" do
    it "fetches only the stored api_url, payload-origin, on the core detail class" do
      fallback_actor(github_id: 101)
      executor = recording_executor do |request, _call|
        detail_success(request, body: actor_body(github_id: 101))
      end

      runner(executor).call(entity_class: GithubActor)

      expect(executor.requests.length).to eq(1)
      expect(executor.requests.first).to have_attributes(
        url: "https://api.github.com/users/user-101",
        request_class: :actor, origin: :payload, borrow: false
      )
    end

    it "carries the caller's borrow authorization through to the request" do
      fallback_actor(github_id: 102)
      executor = recording_executor do |request, _call|
        detail_success(request, body: actor_body(github_id: 102))
      end

      runner(executor).call(entity_class: GithubActor, borrow: true)

      expect(executor.requests.first.borrow).to be(true)
    end

    it "returns idle without a request when nothing is claimable" do
      executor = recording_executor { raise "must not be called" }

      result = runner(executor).call(entity_class: GithubActor)

      expect(result).to have_attributes(status: "idle", github_id: nil, batch_id: nil)
      expect(executor.requests).to be_empty
    end
  end

  describe "a successful fetch" do
    it "projects the document, appends a detail observation, and finalizes the batch" do
      fallback_actor(github_id: 201)
      allow(Rails.logger).to receive(:info)
      executor = recording_executor do |request, _call|
        detail_success(request, body: actor_body(github_id: 201))
      end

      result = runner(executor).call(entity_class: GithubActor)
      row = GithubActor.find_by(github_id: 201)
      observation = EnrichmentObservation.find_by(entity_github_id: 201)

      expect(result).to have_attributes(status: "completed", github_id: 201, reason: nil)
      expect(row).to have_attributes(
        enrichment_status: "complete", enrichment_stage: "contract_complete",
        account_type: "User", detail_attempts: 1, enrichment_attempts: 0,
        fetched_at: now, batch_applied_at: now, contract_completed_at: now,
        latest_observation_id: observation.id, latest_observation_source: "detail",
        lease_token: nil, current_enrichment_batch_id: nil
      )
      expect(observation).to have_attributes(source: "detail", validation_outcome: "applied",
                                             enrichment_batch_id: result.batch_id)
      expect(EnrichmentBatch.find(result.batch_id)).to have_attributes(
        status: "succeeded", returned_count: 1, valid_count: 1, response_status: 200,
        response_body: nil, rate_limit_resource: "core", rate_limit_remaining: 55
      )
      expect(Rails.logger).to have_received(:info).with(
        hash_including(event: "enrichment.detail_completed", github_actor_id: 201,
                       detail_attempts: 1)
      )
    end
  end

  describe "a confirmed-gone entity" do
    it "is terminal immediately, even on the first attempt, with the evidence retained" do
      row = fallback_actor(github_id: 301)
      prior = Github::Enrichment::ObservationRecorder.record!(
        entity_type: Github::Enrichment::EntityType.fetch(:actor), entity_github_id: 301,
        source: :event, raw_payload: { "id" => 301 }, observed_at: now - 600,
        validation_outcome: "applied"
      )
      allow(Rails.logger).to receive(:warn)
      executor = recording_executor do |request, _call|
        Github::FetchResult.from_response(request: request, status: 404,
                                          headers: core_headers,
                                          body: '{"message":"Not Found"}', duration_ms: 1.0)
      end

      result = runner(executor).call(entity_class: GithubActor)

      expect(result).to have_attributes(status: "terminal", reason: "entity_gone_404")
      expect(row.reload).to have_attributes(
        enrichment_status: "permanent_failure", enrichment_stage: "terminal",
        terminal_at: now, last_error: "entity_gone_404", detail_attempts: 1,
        next_retry_at: nil, lease_token: nil,
        # The event-native identity survives the terminal outcome.
        login: "user-301", api_url: "https://api.github.com/users/user-301"
      )
      expect(EnrichmentObservation.exists?(prior.id)).to be(true)
      expect(EnrichmentBatch.find(result.batch_id).status).to eq("failed")
      expect(Rails.logger).to have_received(:warn).with(
        hash_including(event: "enrichment.detail_terminal", reason: "entity_gone_404")
      )
    end

    # Found in live traffic, not in design: the actor `github-actions[bot]` carries a
    # login with brackets, so the URL its own event supplied is unparsable and
    # Github::UrlPolicy refuses it before the gate. §10 classifies a policy violation
    # as permanent, and the ladder would otherwise spend the scarce core detail
    # allowance three times refusing the same stored string.
    it "is terminal immediately when the stored URL cannot pass the SSRF policy" do
      row = fallback_actor(github_id: 302,
                           api_url: "https://api.github.com/users/github-actions[bot]")
      allow(Rails.logger).to receive(:warn)

      # The real executor, so the refusal comes from Github::UrlPolicy itself rather
      # than from a double asserting what it would have done. Nothing reaches a socket:
      # validation happens before the gate, and WebMock would refuse it regardless.
      result = runner(
        Github::RequestExecutor.new(transport: Github::Transports::Faraday.new,
                                    mode: :live, sleeper: ->(_seconds) { },
                                    clock: -> { now })
      ).call(entity_class: GithubActor)

      expect(result.status).to eq("terminal")
      expect(row.reload).to have_attributes(
        enrichment_status: "permanent_failure", enrichment_stage: "terminal",
        terminal_at: now, detail_attempts: 1, next_retry_at: nil
      )
      expect(row.last_error).to match(/unparsable/)
    end
  end

  describe "the retry ladder" do
    it "reschedules a transport failure in detail_pending with the backoff instant" do
      fallback_actor(github_id: 401)
      allow(Rails.logger).to receive(:warn)
      executor = recording_executor { |request, _call| transport_failure(request) }

      result = runner(executor).call(entity_class: GithubActor)
      row = GithubActor.find_by(github_id: 401)

      expect(result.status).to eq("retry_scheduled")
      # detail_pending, never retry_scheduled: that stage belongs to the batch path,
      # and re-batching would spend Search budget reproducing the same miss.
      expect(row).to have_attributes(
        enrichment_status: "retryable_failure", enrichment_stage: "detail_pending",
        detail_attempts: 1, enrichment_attempts: 1,
        next_retry_at: now + 60, retry_scheduled_at: now,
        last_error: "connection refused", lease_token: nil
      )
      expect(EnrichmentBatch.sole).to have_attributes(status: "failed", invalid_count: 1)
      expect(Rails.logger).to have_received(:warn).with(
        hash_including(event: "enrichment.detail_retry_scheduled", detail_attempts: 1)
      )
    end

    it "walks a malformed document up the same ladder, retaining it as an observation" do
      fallback_actor(github_id: 411)
      executor = recording_executor do |request, _call|
        detail_success(request, body: "<html>not json</html>")
      end

      result = runner(executor).call(entity_class: GithubActor)
      observation = EnrichmentObservation.find_by(entity_github_id: 411)

      expect(result.status).to eq("retry_scheduled")
      expect(observation.validation_outcome).to eq("unparsable_document")
      expect(observation.raw_payload).to eq("unparsed_body" => "<html>not json</html>")
      expect(GithubActor.find_by(github_id: 411)).to have_attributes(
        enrichment_stage: "detail_pending", detail_attempts: 1, next_retry_at: now + 60
      )
    end

    it "goes terminal at DETAIL_FALLBACK_MAX_ATTEMPTS instead of retrying forever" do
      fallback_actor(github_id: 421, detail_attempts: configuration.detail_fallback_max_attempts - 1)
      executor = recording_executor { |request, _call| transport_failure(request) }

      result = runner(executor).call(entity_class: GithubActor)

      expect(result.status).to eq("terminal")
      expect(GithubActor.find_by(github_id: 421)).to have_attributes(
        enrichment_status: "permanent_failure", enrichment_stage: "terminal",
        terminal_at: now, detail_attempts: configuration.detail_fallback_max_attempts,
        next_retry_at: nil
      )
    end

    # A refresh row that fell back keeps its completed contract: a retryable failure
    # delays the refresh without demoting the business outcome.
    it "keeps a complete refresh row complete while its detail retry backs off" do
      fallback_actor(github_id: 431, enrichment_status: "complete",
                     fetched_at: now - 172_800)
      executor = recording_executor { |request, _call| transport_failure(request) }

      result = runner(executor).call(entity_class: GithubActor)

      expect(result.status).to eq("retry_scheduled")
      expect(GithubActor.find_by(github_id: 431)).to have_attributes(
        enrichment_status: "complete", enrichment_stage: "detail_pending",
        next_retry_at: now + 60
      )
    end
  end

  describe "a rate-limited fetch" do
    it "defers and releases without counting an attempt" do
      active_budget_window(now: now)
      fallback_actor(github_id: 501)
      allow(Rails.logger).to receive(:info)
      executor = recording_executor do |request, _call|
        Github::FetchResult.from_response(request: request, status: 403,
                                          headers: core_headers(remaining: 0),
                                          body: '{"message":"rate limited"}',
                                          duration_ms: 1.0)
      end

      result = runner(executor).call(entity_class: GithubActor)
      row = GithubActor.find_by(github_id: 501)

      expect(result).to have_attributes(status: "deferred", reason: "rate_limited")
      expect(row).to have_attributes(enrichment_stage: "detail_pending",
                                     detail_attempts: 0, enrichment_attempts: 0,
                                     next_retry_at: nil, lease_token: nil)
      expect(EnrichmentBatch.find(result.batch_id).status).to eq("deferred")
      expect(Rails.logger).to have_received(:info).with(
        hash_including(event: "enrichment.detail_deferred", deferral_reason: "rate_limited")
      )
    end
  end

  describe "a lease lost mid-flight" do
    it "reports lease_lost rather than double-applying the projection" do
      fallback_actor(github_id: 601)
      executor = recording_executor do |request, _call|
        GithubActor.where(github_id: 601).update_all(lease_token: SecureRandom.uuid)
        detail_success(request, body: actor_body(github_id: 601))
      end

      result = runner(executor).call(entity_class: GithubActor)

      expect(result).to have_attributes(status: "lease_lost", reason: "lease_lost")
      expect(GithubActor.find_by(github_id: 601).account_type).to be_nil
      expect(EnrichmentBatch.find(result.batch_id)).to have_attributes(
        status: "succeeded", valid_count: 0, invalid_count: 1
      )
    end
  end

  describe "a crash between claim and outcome" do
    it "finalizes the batch as failed, releases the row, and re-raises" do
      fallback_actor(github_id: 701)
      executor = recording_executor { raise RuntimeError, "boom" }

      expect { runner(executor).call(entity_class: GithubActor) }
        .to raise_error(RuntimeError, "boom")

      expect(EnrichmentBatch.sole).to have_attributes(status: "failed",
                                                      last_error: "RuntimeError")
      expect(GithubActor.find_by(github_id: 701)).to have_attributes(
        enrichment_stage: "detail_pending", detail_attempts: 0, lease_token: nil,
        current_enrichment_batch_id: nil
      )
    end
  end
end
