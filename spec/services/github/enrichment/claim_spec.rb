require "rails_helper"

RSpec.describe Github::Enrichment::Claim do
  subject(:claim) { described_class.new(configuration: configuration) }

  let(:configuration) { configuration_with }
  let(:now) { frozen_time }
  let(:actor_type) { Github::Enrichment::EntityType.fetch(:actor) }

  def acquire(pool: :pending, at: now)
    claim.acquire(actor_type, pool: pool, now: at)
  end

  def pending_actor(github_id: 1, **overrides)
    create_actor(github_id: github_id, last_seen_at: now - 60, **overrides)
  end

  describe "#acquire" do
    it "hands back the entity's identity and the URL enrichment will fetch" do
      actor = pending_actor(api_url: "https://api.github.com/users/octocat")

      expect(acquire).to have_attributes(id: actor.id, github_id: actor.github_id,
                                         api_url: "https://api.github.com/users/octocat",
                                         pool: :pending, enrichment_status: "pending")
    end

    it "pushes next_retry_at into the future, which is what marks the row in flight" do
      pending_actor

      lease = acquire

      expect(lease.leased_until).to eq(now + claim.lease_seconds)
      expect(GithubActor.sole.next_retry_at).to eq(lease.leased_until)
    end

    it "returns nothing when no candidate is eligible" do
      expect(acquire).to be_nil
    end

    # S3.6: "Prevent duplicate concurrent enrichment (keyed by the entity row)." The lease
    # is what makes the second claim find nothing rather than a second worker fetching the
    # same entity and spending a second request on it.
    it "prevents a second worker from claiming the same entity" do
      pending_actor

      expect(acquire).not_to be_nil
      expect(acquire).to be_nil
    end

    it "hands the next-best candidate to a second claim when one exists" do
      pending_actor(github_id: 1, last_seen_at: now - 10)
      pending_actor(github_id: 2, last_seen_at: now - 600)

      expect(acquire.github_id).to eq(1)
      expect(acquire.github_id).to eq(2)
    end

    # A SIGKILL mid-fetch leaves nothing but a column value. There is no lock to release
    # and no transaction to roll back, because none is held across the HTTP call.
    it "makes a crashed worker's entity claimable again once the lease expires" do
      pending_actor
      lease = acquire

      expect(acquire(at: lease.leased_until - 1)).to be_nil
      expect(acquire(at: lease.leased_until)).not_to be_nil
    end

    # GithubActor::IDENTITY_MERGE gates every identity refresh on
    # EXCLUDED.updated_at >= the stored value, so a lease that bumped updated_at would make
    # a concurrently-processed page whose received_at predates it silently lose its
    # refresh — to a write that may be released a second later.
    it "does not move updated_at, because a lease is not observable state" do
      actor = pending_actor

      expect { acquire }.not_to change { actor.reload.updated_at }
    end

    it "leaves the enrichment status and the attempt count alone, because no fetch has happened" do
      actor = pending_actor(enrichment_status: "retryable_failure", enrichment_attempts: 2)

      acquire

      expect(actor.reload).to have_attributes(enrichment_status: "retryable_failure", enrichment_attempts: 2)
    end

    it "carries the attempt count forward so the backoff knows which attempt this is" do
      pending_actor(enrichment_status: "retryable_failure", enrichment_attempts: 2)

      expect(acquire.enrichment_attempts).to eq(2)
    end

    # The pending statement's guard names CANDIDATE_STATUSES, which excludes `complete`, so
    # one statement provably cannot serve both pools.
    it "claims a refresh candidate, which the pending statement's status guard excludes" do
      create_actor(github_id: 1, enrichment_status: "complete", fetched_at: now - 90_000,
                   last_seen_at: now - 60)

      expect(acquire(pool: :pending)).to be_nil
      expect(acquire(pool: :refresh)).to have_attributes(pool: :refresh, enrichment_status: "complete")
    end

    it "refuses an unknown pool rather than claiming from the wrong one" do
      expect { claim.acquire(actor_type, pool: :everything, now: now) }
        .to raise_error(ArgumentError, /everything/)
    end
  end

  describe "#release!" do
    # §7's "failures stay spent" has a mirror here: a deferral leaves no trace. That is
    # what makes the whole-row assertion below possible, and it is why the release
    # restores the prior instant rather than nulling it.
    it "leaves the row byte-for-byte as it found it" do
      actor = pending_actor
      before = actor.reload.attributes

      claim.release!(acquire)

      expect(actor.reload.attributes).to eq(before)
    end

    it "restores the exact prior retry instant rather than clearing it" do
      actor = pending_actor(next_retry_at: now - 60)

      claim.release!(acquire)

      expect(actor.reload.next_retry_at).to eq(now - 60)
    end

    it "makes the entity immediately claimable again" do
      pending_actor
      claim.release!(acquire)

      expect(acquire).not_to be_nil
    end

    # lease_seconds is the worst-case runtime by construction, so a lease expiring
    # mid-flight is reachable. Without the guard a late release would clear a *different*
    # worker's fresh lease.
    it "refuses to release a lease it no longer holds" do
      pending_actor
      lease = acquire
      GithubActor.sole.update!(next_retry_at: now + 9_999)

      expect(claim.release!(lease)).to be(false)
      expect(GithubActor.sole.next_retry_at).to eq(now + 9_999)
    end
  end

  describe "#lease_seconds" do
    # Derived rather than chosen, following RequestGate::WAIT_SECONDS' precedent: every
    # term is a real component's worst case, so retuning a timeout retunes the lease.
    it "derives from the gate wait, both HTTP timeouts, the retries and the redirects" do
      derived = described_class.new(configuration: configuration_with(MAX_HTTP_RETRIES: "0",
                                                                      MAX_REDIRECTS: "0"),
                                    gate_wait_seconds: 10)

      # One attempt x one hop x (10 + 5 + 15), plus one attempt's worth of backoff.
      expect(derived.lease_seconds).to eq(32)
    end

    it "grows with the retries a single fetch may make" do
      fewer = described_class.new(configuration: configuration_with(MAX_HTTP_RETRIES: "0"))

      expect(claim.lease_seconds).to be > fewer.lease_seconds
    end

    it "outlasts the worst case of one gated attempt, so a lease cannot expire mid-request" do
      per_request = Github::RequestGate::WAIT_SECONDS +
                    configuration.http_open_timeout_seconds +
                    configuration.http_read_timeout_seconds

      expect(claim.lease_seconds).to be > per_request
    end
  end
end
