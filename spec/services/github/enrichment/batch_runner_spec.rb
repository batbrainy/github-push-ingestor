require "rails_helper"

# One Search request against a claimed batch, applied item-by-item on the stable
# GitHub id. The executor is a hand-rolled recorder (the request_executor_spec
# anonymous-class idiom) returning FetchResults this file constructs, so every
# branch of the response matrix is exercised without a transport or a corpus.
RSpec.describe Github::Enrichment::BatchRunner do
  let(:now) { frozen_time }
  let(:configuration) { Github.configuration }

  # Records every Request it is handed and answers from the example's script —
  # the state of the world at call time is the recording, never an assumption.
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
      claim: Github::Enrichment::BatchClaim.new(configuration: configuration),
      backoff: jitterless_backoff(configuration: configuration),
      clock: -> { now }
    )
  end

  def search_headers(remaining: 9, used: 1)
    { "x-ratelimit-resource" => "search", "x-ratelimit-limit" => "10",
      "x-ratelimit-remaining" => remaining.to_s, "x-ratelimit-used" => used.to_s,
      "x-ratelimit-reset" => (frozen_time + 60).to_i.to_s }
  end

  def search_success(request, items:, total_count: items.length, incomplete_results: false)
    Github::FetchResult.from_response(
      request: request, status: 200, headers: search_headers,
      body: JSON.generate("total_count" => total_count,
                          "incomplete_results" => incomplete_results, "items" => items),
      duration_ms: 1.0
    )
  end

  def failure_response(request, status:, headers: search_headers, body: "")
    Github::FetchResult.from_response(request: request, status: status, headers: headers,
                                      body: body, duration_ms: 1.0)
  end

  def actor_item(github_id:, login:, type: "User")
    { "id" => github_id, "login" => login, "type" => type }
  end

  def repository_item(github_id:, full_name:, description: "a fixture repository")
    { "id" => github_id, "full_name" => full_name, "description" => description,
      "language" => "Ruby", "owner" => { "id" => 42, "login" => full_name.split("/").first },
      "fork" => false, "archived" => false, "default_branch" => "main",
      "created_at" => "2020-01-01T00:00:00Z" }
  end

  def create_pending_actor(github_id:, login:, created_at: now - 60, **overrides)
    create_actor(github_id: github_id, login: login, created_at: created_at, **overrides)
  end

  describe "an idle claim" do
    it "returns idle without spending a request or creating a batch row" do
      executor = recording_executor { raise "must not be called" }

      result = runner(executor).call(entity_class: GithubActor)

      expect(result).to have_attributes(status: "idle", entity_type: :actor,
                                        batch_id: nil, requested_count: 0)
      expect(executor.requests).to be_empty
      expect(EnrichmentBatch.count).to eq(0)
    end
  end

  describe "a successful batch" do
    it "applies every item by its stable id even when the response order is shuffled" do
      create_pending_actor(github_id: 101, login: "alpha", created_at: now - 30)
      create_pending_actor(github_id: 102, login: "beta", created_at: now - 20)
      create_pending_actor(github_id: 103, login: "gamma", created_at: now - 10)
      executor = recording_executor do |request, _call|
        search_success(request, items: [ actor_item(github_id: 103, login: "gamma"),
                                         actor_item(github_id: 101, login: "alpha"),
                                         actor_item(github_id: 102, login: "beta") ])
      end

      result = runner(executor).call(entity_class: GithubActor)

      expect(result).to have_attributes(status: "completed", requested_count: 3,
                                        returned_count: 3, valid_count: 3, fallback_count: 0)
      [ [ 101, "alpha" ], [ 102, "beta" ], [ 103, "gamma" ] ].each do |github_id, login|
        row = GithubActor.find_by(github_id: github_id)
        expect(row).to have_attributes(
          enrichment_status: "complete", enrichment_stage: "contract_complete",
          account_type: "User", fetched_at: now, batch_applied_at: now,
          contract_completed_at: now, latest_observation_source: "search",
          latest_observed_at: now, enrichment_attempts: 0,
          lease_token: nil, leased_until: nil, current_enrichment_batch_id: nil
        )
        expect(row.raw_payload).to eq(actor_item(github_id: github_id, login: login))
      end
    end

    it "sends one application-origin Search request through the executor" do
      create_pending_actor(github_id: 111, login: "alpha")
      executor = recording_executor do |request, _call|
        search_success(request, items: [ actor_item(github_id: 111, login: "alpha") ])
      end

      runner(executor).call(entity_class: GithubActor)

      expect(executor.requests.length).to eq(1)
      expect(executor.requests.first).to have_attributes(
        request_class: :actor_search, origin: :application,
        url: "https://api.github.com/search/users?q=user%3Aalpha&per_page=1"
      )
    end

    it "appends one applied observation per item, linked to the batch" do
      create_pending_actor(github_id: 121, login: "alpha")
      executor = recording_executor do |request, _call|
        search_success(request, items: [ actor_item(github_id: 121, login: "alpha") ])
      end

      result = runner(executor).call(entity_class: GithubActor)
      observation = EnrichmentObservation.find_by(entity_github_id: 121)

      expect(observation).to have_attributes(
        entity_kind: "actor", source: "search", validation_outcome: "applied",
        enrichment_batch_id: result.batch_id, requested_identifier: "alpha",
        observed_at: now
      )
      expect(observation.raw_payload).to eq(actor_item(github_id: 121, login: "alpha"))
      expect(GithubActor.find_by(github_id: 121).latest_observation_id).to eq(observation.id)
    end

    it "finalizes the batch envelope with counts and the response's rate-limit headers" do
      create_pending_actor(github_id: 131, login: "alpha")
      executor = recording_executor do |request, _call|
        search_success(request, items: [ actor_item(github_id: 131, login: "alpha") ])
      end

      result = runner(executor).call(entity_class: GithubActor)
      batch = EnrichmentBatch.find(result.batch_id)

      expect(batch).to have_attributes(
        status: "succeeded", completed_at: now, requested_count: 1, returned_count: 1,
        valid_count: 1, missing_count: 0, invalid_count: 0, total_count: 1,
        incomplete_results: false, response_status: 200, response_body: nil,
        rate_limit_resource: "search", rate_limit_limit: 10, rate_limit_remaining: 9,
        rate_limit_used: 1, rate_limit_reset_at: Time.zone.at((frozen_time + 60).to_i)
      )
    end

    # §45 throughput counts first completions; a refresh must re-stamp fetched_at
    # without re-counting the entity, which is what the COALESCE keep-first proves.
    it "preserves contract_completed_at across a refresh re-application" do
      create_pending_actor(github_id: 141, login: "alpha")
      respond = lambda do |request, _call|
        search_success(request, items: [ actor_item(github_id: 141, login: "alpha") ])
      end
      runner(recording_executor(&respond)).call(entity_class: GithubActor)
      GithubActor.where(github_id: 141)
                 .update_all(fetched_at: now - 172_800, last_seen_at: now)

      later = now + 60
      runner(recording_executor(&respond), now: later).call(entity_class: GithubActor)
      row = GithubActor.find_by(github_id: 141)

      expect(row.contract_completed_at).to eq(now)
      expect(row).to have_attributes(fetched_at: later, batch_applied_at: later,
                                     enrichment_status: "complete")
    end
  end

  describe "items the response could not validate" do
    it "admits a missing item to the detail fallback and counts it missing" do
      create_pending_actor(github_id: 201, login: "alpha", created_at: now - 30)
      create_pending_actor(github_id: 202, login: "vanished", created_at: now - 20)
      allow(Rails.logger).to receive(:info)
      executor = recording_executor do |request, _call|
        search_success(request, items: [ actor_item(github_id: 201, login: "alpha") ])
      end

      result = runner(executor).call(entity_class: GithubActor)
      row = GithubActor.find_by(github_id: 202)

      expect(result).to have_attributes(status: "completed", valid_count: 1, fallback_count: 1)
      expect(row).to have_attributes(
        enrichment_status: "pending", enrichment_stage: "detail_pending",
        detail_pending_at: now, last_error: "missing_search_result",
        lease_token: nil, current_enrichment_batch_id: nil
      )
      expect(EnrichmentBatch.find(result.batch_id).missing_count).to eq(1)
      expect(Rails.logger).to have_received(:info).with(
        hash_including(event: "enrichment.fallback_admitted", entity_type: :actor,
                       github_actor_id: 202, reason: "missing_search_result")
      )
    end

    # The id matched but the name no longer does, even case-insensitively: GitHub
    # renamed the repository, and the projection must not adopt the new identity.
    it "routes a renamed repository to the fallback instead of projecting it" do
      create_repository(github_id: 301, full_name: "octocat/hello-world")
      executor = recording_executor do |request, _call|
        search_success(request, items: [ repository_item(github_id: 301,
                                                         full_name: "octocat/renamed") ])
      end

      result = runner(executor).call(entity_class: GithubRepository)
      row = GithubRepository.find_by(github_id: 301)

      expect(row).to have_attributes(enrichment_status: "pending",
                                     enrichment_stage: "detail_pending",
                                     description: nil, last_error: "renamed_repository")
      expect(EnrichmentObservation.find_by(entity_github_id: 301).validation_outcome)
        .to eq("renamed_repository")
      expect(EnrichmentBatch.find(result.batch_id)).to have_attributes(valid_count: 0,
                                                                       invalid_count: 1)
    end

    # casecmp, not ==: GitHub canonicalizes case freely, and a case-only difference
    # is the same repository.
    it "still applies a repository whose full_name differs only in case" do
      create_repository(github_id: 311, full_name: "octocat/hello-world")
      executor = recording_executor do |request, _call|
        search_success(request, items: [ repository_item(github_id: 311,
                                                         full_name: "Octocat/Hello-World") ])
      end

      runner(executor).call(entity_class: GithubRepository)

      expect(GithubRepository.find_by(github_id: 311)).to have_attributes(
        enrichment_status: "complete", description: "a fixture repository"
      )
    end

    # Logins are recyclable: an item whose login matches but whose id does not is a
    # different account, and projecting it would corrupt the identity join.
    it "records an identity mismatch when the identifier matches but the id differs" do
      create_pending_actor(github_id: 401, login: "octocat")
      executor = recording_executor do |request, _call|
        search_success(request, items: [ actor_item(github_id: 999, login: "octocat") ])
      end

      result = runner(executor).call(entity_class: GithubActor)
      row = GithubActor.find_by(github_id: 401)

      expect(row).to have_attributes(enrichment_stage: "detail_pending",
                                     last_error: "identity_mismatch", account_type: nil)
      expect(EnrichmentObservation.find_by(entity_github_id: 401).validation_outcome)
        .to eq("identity_mismatch")
      expect(result.fallback_count).to eq(1)
    end

    it "retains an unrequested extra item as evidence without projecting it" do
      create_pending_actor(github_id: 501, login: "alpha")
      executor = recording_executor do |request, _call|
        search_success(request, items: [ actor_item(github_id: 501, login: "alpha"),
                                         actor_item(github_id: 777, login: "stranger") ])
      end

      result = runner(executor).call(entity_class: GithubActor)
      extra = EnrichmentObservation.find_by(entity_github_id: 777)

      expect(extra).to have_attributes(validation_outcome: "unrequested_result",
                                       enrichment_batch_id: result.batch_id)
      expect(GithubActor.find_by(github_id: 777)).to be_nil
      expect(EnrichmentBatch.find(result.batch_id)).to have_attributes(valid_count: 1,
                                                                       invalid_count: 1)
    end

    # incomplete_results is a fact about the query timing out, not about any item
    # that did come back: id-validated items apply, absent ones fall back.
    it "applies id-valid items under incomplete_results while missing ones fall back" do
      create_pending_actor(github_id: 601, login: "alpha", created_at: now - 30)
      create_pending_actor(github_id: 602, login: "slow", created_at: now - 20)
      executor = recording_executor do |request, _call|
        search_success(request, items: [ actor_item(github_id: 601, login: "alpha") ],
                       total_count: 2, incomplete_results: true)
      end

      result = runner(executor).call(entity_class: GithubActor)

      expect(GithubActor.find_by(github_id: 601).enrichment_status).to eq("complete")
      expect(GithubActor.find_by(github_id: 602).enrichment_stage).to eq("detail_pending")
      expect(EnrichmentBatch.find(result.batch_id)).to have_attributes(
        incomplete_results: true, valid_count: 1, missing_count: 1
      )
    end
  end

  describe "a failed request" do
    it "fails the batch on a malformed envelope and schedules every member's retry" do
      create_pending_actor(github_id: 701, login: "alpha", created_at: now - 40)
      create_pending_actor(github_id: 702, login: "beta", created_at: now - 30,
                           enrichment_attempts: 2)
      create_pending_actor(github_id: 703, login: "gamma", created_at: now - 20,
                           enrichment_attempts: 10)
      executor = recording_executor do |request, _call|
        failure_response(request, status: 200, body: "not json at all")
      end

      result = runner(executor).call(entity_class: GithubActor)

      expect(result).to have_attributes(status: "failed",
                                        deferral_reason: "malformed_search_response")
      expect(EnrichmentBatch.find(result.batch_id).status).to eq("failed")
      # Jitterless backoff makes the ladder exact: 60s doubling per prior attempt,
      # capped at the configured hour.
      expect(GithubActor.find_by(github_id: 701)).to have_attributes(
        enrichment_status: "retryable_failure", enrichment_stage: "retry_scheduled",
        enrichment_attempts: 1, next_retry_at: now + 60, retry_scheduled_at: now
      )
      expect(GithubActor.find_by(github_id: 702)).to have_attributes(
        enrichment_attempts: 3, next_retry_at: now + 240
      )
      expect(GithubActor.find_by(github_id: 703)).to have_attributes(
        enrichment_attempts: 11, next_retry_at: now + 3600
      )
    end

    # A refresh member already holds a completed contract; a failed refresh batch
    # must not demote it — the backoff rides next_retry_at while the row rests
    # back in contract_complete.
    it "restores a complete refresh member to contract_complete with its backoff set" do
      create_actor(github_id: 711, login: "alpha", enrichment_status: "complete",
                   enrichment_stage: "contract_complete",
                   fetched_at: now - 172_800, last_seen_at: now - 60)
      executor = recording_executor do |request, _call|
        failure_response(request, status: 200, body: "{}")
      end

      runner(executor).call(entity_class: GithubActor)

      expect(GithubActor.find_by(github_id: 711)).to have_attributes(
        enrichment_status: "complete", enrichment_stage: "contract_complete",
        enrichment_attempts: 1, next_retry_at: now + 60,
        lease_token: nil, current_enrichment_batch_id: nil
      )
    end

    it "fails the batch on a server error and leaves the debited request spent" do
      create_pending_actor(github_id: 721, login: "alpha")
      allow(Rails.logger).to receive(:warn)
      executor = recording_executor do |request, _call|
        failure_response(request, status: 500, body: "Internal Server Error")
      end

      result = runner(executor).call(entity_class: GithubActor)
      batch = EnrichmentBatch.find(result.batch_id)

      expect(result.status).to eq("failed")
      # One attempt was made and there is no refund path: the executor saw exactly
      # one request, and the batch retains the failure evidence.
      expect(executor.requests.length).to eq(1)
      expect(batch).to have_attributes(status: "failed", response_status: 500,
                                       response_body: "Internal Server Error")
      # A server error says nothing about the query, so the identical batch is worth
      # sending again — unlike a 4xx, which is deterministic and takes the fallback.
      expect(GithubActor.find_by(github_id: 721).enrichment_stage).to eq("retry_scheduled")
      expect(Rails.logger).to have_received(:warn).with(
        hash_including(event: "enrichment.batch_failed", response_status: 500)
      )
    end

    # A rejected query is a fact about these identifiers and this URL, and the ladder
    # would resend both unchanged — the same 4xx, hourly, forever. Every deterministic
    # client error therefore takes the bounded fallback, whatever GitHub's wording.
    it "routes any rejected query to the detail lane rather than resending it" do
      create_pending_actor(github_id: 751, login: "alpha")
      allow(Rails.logger).to receive(:warn)
      allow(Rails.logger).to receive(:info)
      executor = recording_executor do |request, _call|
        failure_response(request, status: 422, body: '{"message":"Validation Failed"}')
      end

      result = runner(executor).call(entity_class: GithubActor)

      expect(result).to have_attributes(status: "completed", fallback_count: 1)
      expect(GithubActor.find_by(github_id: 751))
        .to have_attributes(enrichment_stage: "detail_pending",
                            last_error: "search_query_rejected")
      expect(Rails.logger).to have_received(:warn).with(
        hash_including(event: "enrichment.batch_unsearchable",
                       reason: "search_query_rejected", response_status: 422)
      )
    end

    # Observed against the live API: Search answers 422 rather than an empty result set
    # when every requested identifier is unsearchable — the state a renamed repository
    # is in. Retrying the search would reproduce it forever, so the members take the
    # same route an omitted item takes, and the stored payload URL resolves the rename.
    it "admits every member to the detail lane when GitHub says none are searchable" do
      create_pending_actor(github_id: 741, login: "alpha")
      create_pending_actor(github_id: 742, login: "beta")
      allow(Rails.logger).to receive(:warn)
      allow(Rails.logger).to receive(:info)
      executor = recording_executor do |request, _call|
        failure_response(
          request, status: 422,
          body: '{"message":"Validation Failed","errors":[{"message":"The listed users ' \
                'and repositories cannot be searched either because the resources do ' \
                'not exist or you do not have permission to view them.","resource":' \
                '"Search","field":"q","code":"invalid"}]}'
        )
      end

      result = runner(executor).call(entity_class: GithubActor)
      batch = EnrichmentBatch.find(result.batch_id)

      expect(result).to have_attributes(status: "completed", returned_count: 0,
                                        valid_count: 0, fallback_count: 2)
      expect(GithubActor.where(github_id: [ 741, 742 ]).pluck(:enrichment_stage))
        .to all(eq("detail_pending"))
      expect(GithubActor.where(github_id: [ 741, 742 ]).pluck(:last_error))
        .to all(eq("unsearchable_identifier"))
      # No member is left on the search lane, and the batch records why.
      expect(batch).to have_attributes(status: "failed", missing_count: 2,
                                       returned_count: 0,
                                       last_error: "unsearchable_identifier")
      expect(Rails.logger).to have_received(:warn).with(
        hash_including(event: "enrichment.batch_unsearchable", response_status: 422)
      )
    end

    it "stores a failure body truncated to the retention bound" do
      create_pending_actor(github_id: 731, login: "alpha")
      executor = recording_executor do |request, _call|
        failure_response(request, status: 422, body: "x" * 70_000)
      end

      result = runner(executor).call(entity_class: GithubActor)

      expect(EnrichmentBatch.find(result.batch_id).response_body.length)
        .to eq(described_class::RESPONSE_BODY_LIMIT)
    end
  end

  describe "a rate-limited request" do
    { 403 => { remaining: 0, reason: "rate_limited" },
      429 => { remaining: 5, reason: "secondary_limited" } }.each do |status, expected|
      it "defers the batch on #{status} and releases the rows unchanged" do
        active_search_window(now: now)
        create_pending_actor(github_id: 801, login: "alpha")
        original = GithubActor.find_by(github_id: 801).attributes
        allow(Rails.logger).to receive(:info)
        executor = recording_executor do |request, _call|
          failure_response(request, status: status,
                           headers: search_headers(remaining: expected[:remaining]),
                           body: "limited")
        end

        result = runner(executor).call(entity_class: GithubActor)
        restored = GithubActor.find_by(github_id: 801).attributes

        expect(result).to have_attributes(status: "deferred",
                                          deferral_reason: expected[:reason])
        # Deferral is not an attempt: everything but updated_at is byte-identical.
        expect(restored.except("updated_at")).to eq(original.except("updated_at"))
        expect(EnrichmentBatch.find(result.batch_id)).to have_attributes(
          status: "deferred", last_error: expected[:reason]
        )
        # Both block the Search lane, by different routes: a primary exhaustion is this
        # resource's own fact and takes the reset instant it reported, while a secondary
        # limit is IP-scoped and takes Github::RateLimitPolicy's escalating floor.
        if expected[:reason] == "rate_limited"
          expect(current_search_budget.blocked_until).to eq(Time.zone.at((frozen_time + 60).to_i))
        else
          expect(current_search_budget.blocked_until)
            .to be >= frozen_time + Github::RateLimitPolicy::MIN_BLOCK_SECONDS
        end
        expect(Rails.logger).to have_received(:info).with(
          hash_including(event: "enrichment.batch_deferred", deferral_reason: expected[:reason])
        )
      end
    end
  end

  describe "a lease lost mid-flight" do
    it "counts the item invalid rather than applying over a foreign lease" do
      create_pending_actor(github_id: 901, login: "alpha")
      executor = recording_executor do |request, _call|
        # Another claimant stole the row between our request and our write.
        GithubActor.where(github_id: 901).update_all(lease_token: SecureRandom.uuid)
        search_success(request, items: [ actor_item(github_id: 901, login: "alpha") ])
      end

      result = runner(executor).call(entity_class: GithubActor)
      row = GithubActor.find_by(github_id: 901)

      expect(result).to have_attributes(status: "completed", valid_count: 0)
      expect(row).to have_attributes(enrichment_status: "pending", account_type: nil)
      expect(EnrichmentBatch.find(result.batch_id)).to have_attributes(valid_count: 0,
                                                                       invalid_count: 1)
    end
  end

  describe "a crash between claim and outcome" do
    [ RuntimeError, Github::Errors::FixtureMiss ].each do |error_class|
      it "finalizes the batch, releases the rows, and re-raises #{error_class}" do
        create_pending_actor(github_id: 951, login: "alpha")
        executor = recording_executor { raise error_class, "boom" }

        expect { runner(executor).call(entity_class: GithubActor) }
          .to raise_error(error_class, "boom")

        expect(EnrichmentBatch.sole).to have_attributes(status: "failed",
                                                        last_error: error_class.name,
                                                        completed_at: now)
        expect(GithubActor.find_by(github_id: 951)).to have_attributes(
          enrichment_stage: "batch_pending", enrichment_attempts: 0,
          next_retry_at: nil, lease_token: nil, current_enrichment_batch_id: nil
        )
      end
    end
  end
end
