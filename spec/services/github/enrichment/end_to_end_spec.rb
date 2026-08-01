require "rails_helper"

# §12: "GITHUB_MODE=fixture selects the FixtureEvents source and the Fixture transport —
# beneath both polling *and* enrichment, so the complete flow (poll → persist → stub →
# enrich) runs with zero network."
#
# The corpus already supports this with no new fixture authoring. Page 1 persists four push
# events (1, 2, 3 and 8; 4 is a WatchEvent and 5-7 quarantine, and the quarantine path
# writes no stubs), producing three actors and three repositories. Four resolve 200 and two
# resolve 404 — which is what fixtures/github/README.md documents event 8 for.
RSpec.describe "enrichment end to end", type: :integration do
  let(:now) { frozen_time }
  let(:transport) { fixture_transport }
  let(:runner) { fixture_enrichment_runner(transport: transport, now: now) }

  # One transport for the whole flow, so the poll and the enrichment requests share a
  # scripted cursor exactly as one process would.
  def ingest!(at: now, force: false)
    fixture_runner(transport: transport, now: at)
      .call(event_source: fixture_event_source, force: force)
  end

  def enrich!(cycles: 1, **arguments)
    Array.new(cycles) { runner.call(**arguments) }
  end

  describe "the whole flow with no network at all" do
    before do
      ingest!
      enrich!(cycles: 6)
    end

    it "persists four push events and three entities of each class" do
      expect(PushEvent.count).to eq(4)
      expect(GithubActor.count).to eq(3)
      expect(GithubRepository.count).to eq(3)
    end

    it "enriches both resolvable actors in the finite fixture corpus" do
      expect(GithubActor.find_by(github_id: 583_231))
        .to have_attributes(enrichment_status: "complete", name: "The Octocat", fetched_at: now)
      expect(GithubActor.find_by(github_id: 1_024_025))
        .to have_attributes(enrichment_status: "complete", name: "Mona Lisa Octocat")
    end

    it "writes §7's enrichment-owned columns for the fixture's resolved repository" do
      expect(GithubRepository.find_by(github_id: 1_296_269)).to have_attributes(
        enrichment_status: "complete", description: "My first repository on GitHub!",
        language: "Ruby", owner_github_id: 583_231
      )
    end

    # §10: "actor or repo URL returns 404/410 → entity permanent_failure; source stays
    # enabled."
    it "marks the two entities that no longer exist permanently failed" do
      expect(GithubActor.find_by(github_id: 7_700_421).enrichment_status).to eq("permanent_failure")
      expect(GithubRepository.find_by(github_id: 1_490_033).enrichment_status).to eq("permanent_failure")
    end

    it "never disables the event source over an entity that disappeared" do
      expect(EventSource.sole).to have_attributes(status: "idle", enabled: true)
    end

    it "spends exactly one enrichment request per entity, split evenly across the classes" do
      expect(current_budget).to have_attributes(enrichment_used: 6, actor_share_used: 3,
                                                repository_share_used: 3)
    end

    it "stays well inside both fairness guarantees, so neither class starved the other" do
      expect(current_budget.actor_share_used).to be <= 20
      expect(current_budget.repository_share_used).to be <= 20
    end

    # §7 and ADR 0001: raw retention is semantic, not byte-exact — jsonb preserves neither
    # whitespace nor key order.
    it "retains each enriched document as jsonb, content-equivalent to the corpus body" do
      body = JSON.parse(Rails.root.join("fixtures/github/bodies/users/octocat.json").read)

      expect(GithubActor.find_by(github_id: 583_231).raw_payload).to eq(body)
    end

    # §7 is explicit that the envelope's repo.name is the qualified form and "is **not**
    # silently equated with the enriched name". Both columns are envelope-owned.
    it "leaves the repository name envelope-derived, which enrichment must never overwrite" do
      expect(GithubRepository.find_by(github_id: 1_296_269))
        .to have_attributes(name: "Hello-World", full_name: "octocat/Hello-World")
    end

    it "makes no network request at any point" do
      expect(WebMock).not_to have_requested(:any, //)
    end
  end

  describe "the freshness cache (plan §10, S3.5)" do
    before do
      ingest!
      enrich!(cycles: 6)
    end

    it "has nothing left to do once every entity is decided" do
      expect(runner.call).to have_attributes(status: "idle", deferral_reason: "no_candidate")
    end

    it "spends no further budget on a fresh record" do
      expect { runner.call }.not_to change { current_budget.enrichment_used }.from(6)
    end

    it "refreshes the most stale record once its TTL has passed" do
      later = now + 86_401
      stale = fixture_enrichment_runner(transport: transport, now: later)

      result = stale.call

      expect(result).to have_attributes(status: "enriched", pool: :refresh)
      expect(GithubActor.find_by(github_id: result.github_id).fetched_at).to eq(later)
    end
  end

  # §12's named sequence, in one example each: "Enrichment allowance exhaustion → deferred →
  # skipped_budget → reactivation only via a genuinely new event."
  describe "exhaustion, skip and reactivation" do
    let(:actor) { GithubActor.find_by(github_id: 583_231) }

    before { ingest! }

    it "defers without touching the entity when the allowance is gone" do
      active_budget_window(now: now, enrichment_used: 40)
      before = actor.attributes

      expect(runner.call).to have_attributes(status: "deferred", deferral_reason: "class_exhausted")
      expect(actor.reload.attributes).to eq(before)
    end

    it "skips the entity once its activity ages past the eligibility window" do
      later = now + 3601
      fixture_enrichment_runner(transport: transport, now: later).call

      expect(actor.reload).to have_attributes(enrichment_status: "skipped_budget", skipped_at: later)
    end

    it "reactivates a skipped entity when a genuinely new event references it" do
      GithubActor.where(github_id: 583_231)
                 .update_all(enrichment_status: "skipped_budget", skipped_at: now)

      Github::Ingestion::PageWriter.new(clock: -> { now + 60 }).write(
        [ well_formed_envelope("id" => "58000000099", "payload" => { "push_id" => 27_500_000_099 }) ],
        run_id: "reactivation"
      )

      expect(actor.reload).to have_attributes(enrichment_status: "pending", skipped_at: nil)
    end

    # §7 rule 4, and the README's Phase B replay check: a duplicate replay must emit no
    # enrichment.reactivated event.
    it "never reactivates a skipped entity on a duplicate replay" do
      GithubActor.where(github_id: 583_231)
                 .update_all(enrichment_status: "skipped_budget", skipped_at: now)

      Github::Ingestion::PageWriter.new(clock: -> { now + 60 })
                                   .write([ well_formed_envelope ], run_id: "replay")

      expect(actor.reload).to have_attributes(enrichment_status: "skipped_budget", skipped_at: now)
    end
  end

  # §12: "Class fairness: repository flood cannot starve actors (and vice versa)."
  describe "class fairness under a one-sided backlog" do
    before do
      ingest!
      active_budget_window(now: now, actor_share_used: 20, repository_share_used: 0, enrichment_used: 20)
    end

    it "serves the class that has not spent its guarantee" do
      expect(runner.call).to have_attributes(entity_type: :repository, borrow: false)
    end

    it "borrows for the spent class only once the other has nothing eligible left" do
      GithubRepository.update_all(enrichment_status: "permanent_failure")

      expect(runner.call).to have_attributes(entity_type: :actor, borrow: true)
    end
  end

  # §12: "Poll allowance protected from enrichment demand — and vice versa (class-blocking
  # isolation: one class exhausted, the other proceeds)."
  describe "class isolation between polling and enrichment" do
    # Polled past GitHub's own X-Poll-Interval floor, which the fixture corpus sets to 60
    # seconds and which --force deliberately does *not* bypass (§9). What is bypassed is
    # only the configured cadence — so a poll that completes here completed *through* the
    # class blocking that enrichment exhaustion would have caused if the two shared one
    # timestamp.
    it "still polls when enrichment has spent its whole allowance" do
      ingest!
      active_budget_window(now: now, enrichment_used: 40, poll_used: 1)

      # A 304 is a poll that happened — §10 keeps its reservation debited — so the
      # assertion is that nothing deferred it, not which body came back.
      expect(ingest!(at: now + 120, force: true)).not_to be_deferred
      expect(current_budget.poll_used).to eq(2)
    end

    # The attempt is what isolation means here. Which entity the fairness policy picked —
    # and whether that one happens to 404 in the corpus — is beside the point; what matters
    # is that a spent poll allowance did not defer it.
    it "still enriches when polling has spent its whole allowance" do
      ingest!
      active_budget_window(now: now, poll_used: 12)

      expect(runner.call).to be_attempted
      expect(current_budget.enrichment_used).to eq(1)
    end
  end
end
