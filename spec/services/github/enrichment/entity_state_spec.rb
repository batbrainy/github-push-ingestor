require "rails_helper"

RSpec.describe Github::Enrichment::EntityState do
  # No jitter, so the backoff instant is exact and the example names a number rather than a
  # range — the technique poll_state_spec.rb uses for the same reason.
  subject(:state) do
    described_class.new(backoff: Github::Enrichment::Backoff.new(random: instance_double(Random, rand: 0.0)))
  end

  let(:now) { frozen_time }
  let(:actor_type) { Github::Enrichment::EntityType.fetch(:actor) }
  let(:github_id) { 583_231 }
  let(:leased_until) { now + 600 }

  let!(:actor) do
    create_actor(github_id: github_id, last_seen_at: now - 60, next_retry_at: leased_until)
  end

  def lease(**overrides)
    Github::Enrichment::Claim::Lease.new(
      **{ entity_type: actor_type, pool: :pending, id: actor.id, github_id: github_id,
          api_url: "https://api.github.com/users/octocat", enrichment_status: "pending",
          enrichment_attempts: 0, fetched_at: nil, last_seen_at: now - 60,
          previous_next_retry_at: nil, leased_until: leased_until }.merge(overrides)
    )
  end

  def fetched(classification:, status: nil, error: nil, body: "", headers: {})
    request = Github::Request.new(url: "https://api.github.com/users/octocat",
                                  request_class: :actor, origin: :payload)
    return Github::FetchResult.from_error(request: request, error: error, classification: classification) if error

    Github::FetchResult.from_response(request: request, status: status, headers: headers,
                                      body: body, duration_ms: 1.0)
  end

  def record(classification:, status: nil, error: nil, body: "", headers: {},
             document: nil, decision: nil, **lease_overrides)
    state.record!(lease: lease(**lease_overrides),
                  fetched: fetched(classification: classification, status: status, error: error,
                                   body: body, headers: headers),
                  document: document, decision: decision, now: now)
  end

  def document_for(body) = Github::Enrichment::ActorDocument.parse(body, github_id: github_id)

  let(:good_body) { JSON.generate("id" => github_id, "name" => "The Octocat") }

  describe "a document that parsed (§10's 200)" do
    it "stores the document and marks the entity complete" do
      written = record(classification: :ok, status: 200, body: good_body, document: document_for(good_body))

      expect(written.outcome).to eq("enriched")
      expect(actor.reload).to have_attributes(enrichment_status: "complete", name: "The Octocat",
                                              fetched_at: now)
      expect(actor.reload.raw_payload).to include("name" => "The Octocat")
    end

    # enrichment_attempts counts attempts *since the last success*, following
    # PollState#success's consecutive_failures: its only two consumers are the backoff
    # exponent and the log line, and both want that number.
    it "resets the attempt count, because it counts attempts since the last success" do
      record(classification: :ok, status: 200, body: good_body, document: document_for(good_body),
             enrichment_attempts: 4)

      expect(actor.reload.enrichment_attempts).to eq(0)
    end

    # A stale error or skip instant on a successful row is a permanent lie —
    # PollState#success's clearing argument, applied to the entity.
    it "clears the failure and skip state, which would otherwise outlive the failure" do
      actor.update!(last_error: "boom", skipped_at: now - 60)

      record(classification: :ok, status: 200, body: good_body, document: document_for(good_body))

      expect(actor.reload).to have_attributes(last_error: nil, skipped_at: nil)
    end

    # The next event for this row is a *refresh*, gated by fetched_at plus the TTL rather
    # than by a retry instant. Leaving the lease would delay it by ten minutes and conflate
    # two meanings on one column.
    it "clears the retry instant, because the next event is a TTL refresh and not a retry" do
      record(classification: :ok, status: 200, body: good_body, document: document_for(good_body))

      expect(actor.reload.next_retry_at).to be_nil
    end
  end

  describe "a document it refuses (§10's malformed row)" do
    let(:malformed) { document_for("<html>") }
    let(:mismatched) { document_for(JSON.generate("id" => 999)) }

    it "treats a malformed body as permanent, because it is a decided fact and not transport noise" do
      written = record(classification: :ok, status: 200, body: "<html>", document: malformed)

      expect(written.outcome).to eq("failed")
      expect(actor.reload).to have_attributes(enrichment_status: "permanent_failure", next_retry_at: nil)
    end

    it "refuses another entity's document under its own error code" do
      written = record(classification: :ok, status: 200, document: mismatched)

      expect(written.error_code).to eq("identity_mismatch")
      expect(actor.reload.enrichment_status).to eq("permanent_failure")
    end

    # A bad refresh must not delete a good document. The payload columns are absent from
    # every failing branch's attribute Hash, so this is structural rather than a check.
    it "keeps the payload it already had, so a bad refresh cannot destroy a good document" do
      actor.update!(enrichment_status: "complete", name: "The Octocat",
                    raw_payload: { "id" => github_id }, fetched_at: now - 90_000)

      record(classification: :ok, status: 200, document: malformed, enrichment_status: "complete")

      expect(actor.reload).to have_attributes(name: "The Octocat", raw_payload: { "id" => github_id })
    end

    it "refuses to record a 200 that was never parsed, which would be a caller bug" do
      expect { record(classification: :ok, status: 200) }.to raise_error(ArgumentError, /parsed/)
    end
  end

  describe "outcomes that are facts about this entity" do
    # §10: "actor or repo URL returns 404/410 → entity permanent_failure; source stays
    # enabled."
    it "marks a 404 permanently failed and schedules no retry" do
      written = record(classification: :not_found, status: 404)

      expect(written.outcome).to eq("failed")
      expect(actor.reload).to have_attributes(enrichment_status: "permanent_failure", next_retry_at: nil,
                                              enrichment_attempts: 1)
      expect(actor.reload.last_error).to include("404")
    end

    # §10: "Never disable the event source because one enrichment target disappeared." The
    # guarantee is structural — this class writes only entity_type.model and physically
    # cannot reach event_sources.
    it "leaves the event source untouched, because one dead entity is not a dead source" do
      source = create_event_source

      expect { record(classification: :not_found, status: 404) }
        .not_to change { source.reload.attributes }
    end

    # 403 and 429 never land here: ResponseClassifier routes both to a limit
    # classification. What does is 400, 422, 451 — all permanent for this row.
    it "marks any other client error permanently failed" do
      record(classification: :client_error, status: 422)

      expect(actor.reload.enrichment_status).to eq("permanent_failure")
    end

    it "schedules a retry for a server error, counting the attempt against this entity" do
      written = record(classification: :server_error, status: 500)

      expect(written.outcome).to eq("failed")
      expect(actor.reload).to have_attributes(enrichment_status: "retryable_failure",
                                              enrichment_attempts: 1, next_retry_at: now + 60)
    end

    it "backs off further with each attempt since the last success" do
      record(classification: :server_error, status: 500, enrichment_attempts: 2)

      expect(actor.reload).to have_attributes(enrichment_attempts: 3, next_retry_at: now + 240)
    end

    it "schedules a retry for a transport failure the same way" do
      record(classification: :transport_error,
             error: Github::Errors::RequestTimeout.new("timed out"))

      expect(actor.reload).to have_attributes(enrichment_status: "retryable_failure", next_retry_at: now + 60)
    end

    # §10: "Violations mark the entity permanent_failure." This covers a URL-policy
    # violation, a TLS failure, and an exhausted redirect budget alike.
    it "marks a URL-policy violation permanently failed and names every reason" do
      violation = Github::Errors::UrlPolicyViolation.new("", [ :blank ])

      record(classification: :permanent_error, error: violation)

      expect(actor.reload.enrichment_status).to eq("permanent_failure")
      expect(actor.reload.last_error).to include("blank")
    end

    # Enrichment sends no validator — §7's column list has no entity ETag, and §10's dated
    # probe established that an unauthenticated 304 debits quota anyway. So a 304 means an
    # assumption broke, and it is handled as an ordinary retryable failure with a WARN.
    it "treats a 304 as retryable, because enrichment never sent a validator" do
      allow(Rails.logger).to receive(:warn)

      record(classification: :not_modified, status: 304)

      expect(actor.reload).to have_attributes(enrichment_status: "retryable_failure", next_retry_at: now + 60)
      expect(Rails.logger).to have_received(:warn).with(hash_including(event: "enrichment.unexpected_not_modified"))
    end

    it "does not bump fetched_at on a 304, which is no evidence that what we hold is current" do
      actor.update!(enrichment_status: "complete", fetched_at: now - 90_000)

      record(classification: :not_modified, status: 304, enrichment_status: "complete")

      expect(actor.reload.fetched_at).to eq(now - 90_000)
    end

    # A transient 500 on a refresh would otherwise drop coverage for a network blip and
    # jump the row into the high-priority pending pool ahead of never-enriched candidates.
    # The status conveys nothing next_retry_at, last_error and the attempt count do not.
    it "never downgrades a complete record on a retryable failure" do
      actor.update!(enrichment_status: "complete", fetched_at: now - 90_000)

      record(classification: :server_error, status: 500, enrichment_status: "complete")

      expect(actor.reload).to have_attributes(enrichment_status: "complete", enrichment_attempts: 1,
                                              next_retry_at: now + 60)
    end

    it "does downgrade a complete record on a terminal outcome, which invalidates the document" do
      actor.update!(enrichment_status: "complete", fetched_at: now - 90_000)

      record(classification: :not_found, status: 404, enrichment_status: "complete")

      expect(actor.reload.enrichment_status).to eq("permanent_failure")
    end
  end

  describe "outcomes that are facts about the IP rather than this entity" do
    # PollState makes exactly this call for the source: "GitHub answered … but nothing is
    # wrong with the source". Inflating an innocent entity's backoff for an IP-wide
    # condition would, repeated, push it toward the hour-long cap.
    it "does not blame the entity for a primary rate limit" do
      before = actor.reload.attributes

      written = record(classification: :rate_limited, status: 403)

      expect(written.outcome).to eq("deferred")
      expect(actor.reload.attributes).to eq(before)
    end

    # §10 requires it: "also update the request-specific source or entity retry state". Not
    # redundant with the global block — ROLL_WINDOW_SQL clears that at the window boundary
    # while this component survives it.
    it "defers this entity as well as the IP on a secondary limit" do
      decision = Github::RateLimitPolicy::Decision.new(kind: :secondary_rate_limit,
                                                       blocked_until: now + 120,
                                                       source_retry_at: now + 120, window_status: nil)

      written = record(classification: :secondary_limited, status: 403, decision: decision)

      expect(written.outcome).to eq("deferred")
      expect(actor.reload).to have_attributes(next_retry_at: now + 120, enrichment_attempts: 0,
                                              enrichment_status: "pending")
    end

    it "falls back to a plain release when a secondary limit named no instant" do
      before = actor.reload.attributes

      record(classification: :secondary_limited, status: 403, decision: nil)

      expect(actor.reload.attributes).to eq(before)
    end

    # §12's sequence is "exhaustion → deferred → skipped_budget": a denial writes nothing at
    # all, and the row becomes skipped only later, when its activity ages out.
    it "leaves the row exactly as it found it on a budget denial" do
      before = actor.reload.attributes

      written = record(classification: :budget_denied,
                       error: Github::Errors::BudgetExhausted.new(:actor, :share_exhausted))

      expect(written).to have_attributes(outcome: "deferred", lease_held: true)
      expect(actor.reload.attributes).to eq(before)
    end

    it "leaves the row exactly as it found it when the gate was held" do
      before = actor.reload.attributes

      record(classification: :gate_unavailable, error: Github::Errors::GateUnavailable.new("busy"))

      expect(actor.reload.attributes).to eq(before)
    end
  end

  describe "a lease that expired mid-flight" do
    # lease_seconds is the worst-case runtime by construction, so this is reachable rather
    # than theoretical. Writing the outcome anyway would be the double-write the lease
    # exists to prevent; reporting it is the graceful degradation.
    it "refuses to write an outcome after another worker claimed the row" do
      allow(Rails.logger).to receive(:warn)
      actor.update!(next_retry_at: now + 9_999)

      written = record(classification: :ok, status: 200, body: good_body, document: document_for(good_body))

      expect(written).to have_attributes(outcome: "lease_lost", lease_held: false)
      expect(actor.reload.enrichment_status).to eq("pending")
      expect(Rails.logger).to have_received(:warn).with(hash_including(event: "enrichment.lease_lost"))
    end
  end

  describe "the disposition table" do
    # A frozen Hash with no default, so an unenumerated classification raises rather than
    # silently taking a branch.
    it "covers every classification a fetch can produce except the unreachable redirect" do
      expect(described_class::DISPOSITIONS.keys)
        .to match_array(Github::FetchResult::CLASSIFICATIONS - [ :redirect ])
    end

    # :redirect never escapes RequestExecutor#follow_redirects — it is either followed or
    # converted into RedirectLimitExceeded, which classifies as :permanent_error.
    it "raises on the classification the executor never returns, rather than guessing" do
      expect { record(classification: :redirect, status: 301, headers: { "location" => "https://api.github.com/x" }) }
        .to raise_error(ArgumentError, /redirect/)
    end

    # FetchResult#successful? answers true for :not_modified, so dispatching on it would
    # send a bodyless 304 down the "store the document" branch.
    it "dispatches on the classification and never on whether the response was successful" do
      expect(described_class::DISPOSITIONS.fetch(:not_modified)).to eq(:retryable)
      expect(Github::ResponseClassifier.successful?(:not_modified)).to be(true)
    end
  end
end
