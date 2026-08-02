require "rails_helper"

# §12: "GITHUB_MODE=fixture selects the FixtureEvents source and the Fixture transport —
# beneath both polling *and* enrichment, so the complete flow (poll → persist → stage →
# enrich) runs with zero network."
#
# The corpus supports the whole staged pipeline. Page 1 persists four push events
# (1, 2, 3 and 8; 4 is a WatchEvent and 5–7 quarantine), producing three actors and
# three repositories in FIFO order. One cycle then issues exactly four requests: one
# Search batch per class (octocat and monalisa resolve; ghostuser and deleted-org/gone
# are missing from the Search results), and one core detail fallback per ghost, both of
# which 404 — fixtures/github/README.md documents event 8 for exactly this.
RSpec.describe "enrichment end to end", type: :integration do
  let(:now) { frozen_time }
  let(:transport) { fixture_transport }
  # Pacing is disabled so the second Search batch of the cycle needs no wall clock;
  # every other knob keeps its pinned default.
  let(:configuration) { configuration_with("GITHUB_MODE" => "fixture", "SEARCH_PACING_SECONDS" => "0") }

  # One transport for the whole flow, so the poll and the enrichment requests share a
  # scripted cursor exactly as one process would.
  def ingest!(at: now)
    fixture_runner(transport: transport, now: at).call(event_source: fixture_event_source)
  end

  # The executor's clock travels with the cycle's: the ledgers roll their windows on
  # the reservation clock, so a cycle asked to run "a minute later" must reserve a
  # minute later too, exactly as one process would.
  def run_cycle!(at: now)
    executor = fixture_executor(transport: transport, ledger: ledger_for(configuration),
                                search_ledger: search_ledger_for(configuration),
                                clock: -> { at })

    fixture_cycle_runner(
      transport: transport, now: at, configuration: configuration,
      batch_runner: fixture_batch_runner(transport: transport, now: at,
                                         configuration: configuration, executor: executor),
      detail_runner: fixture_detail_runner(transport: transport, now: at,
                                           configuration: configuration, executor: executor)
    ).call
  end

  describe "one cycle over the freshly ingested corpus, with no network at all" do
    before do
      ingest!
      @cycle = run_cycle!
    end

    it "persists four push events and three entities of each class" do
      expect(PushEvent.count).to eq(4)
      expect(GithubActor.count).to eq(3)
      expect(GithubRepository.count).to eq(3)
    end

    it "completes both resolvable actors from one Search batch" do
      expect(GithubActor.find_by(github_id: 583_231)).to have_attributes(
        enrichment_status: "complete", enrichment_stage: "contract_complete",
        account_type: "User", fetched_at: now, batch_applied_at: now,
        contract_completed_at: now, latest_observation_source: "search"
      )
      expect(GithubActor.find_by(github_id: 1_024_025))
        .to have_attributes(enrichment_status: "complete", enrichment_stage: "contract_complete")
    end

    it "completes both resolvable repositories with the staged contract columns" do
      expect(GithubRepository.find_by(github_id: 1_296_269)).to have_attributes(
        enrichment_status: "complete", enrichment_stage: "contract_complete",
        description: "My first repository on GitHub!", language: "Ruby",
        owner_github_id: 583_231, owner_login: "octocat",
        fork: false, archived: false, default_branch: "main"
      )
      expect(GithubRepository.find_by(github_id: 1_300_192)).to have_attributes(
        enrichment_status: "complete", default_branch: "trunk", description: nil
      )
    end

    # §10: "actor or repo URL returns 404/410 → entity permanent_failure; source stays
    # enabled" — reached through the staged path: missing from Search, admitted to the
    # bounded detail lane, confirmed gone there.
    it "sends both ghosts down the detail lane to an entity-specific terminal" do
      expect(GithubActor.find_by(github_id: 7_700_421)).to have_attributes(
        enrichment_status: "permanent_failure", enrichment_stage: "terminal",
        terminal_at: now, last_error: "entity_gone_404"
      )
      expect(GithubRepository.find_by(github_id: 1_490_033)).to have_attributes(
        enrichment_status: "permanent_failure", enrichment_stage: "terminal"
      )
    end

    it "never disables the event source over entities that disappeared" do
      expect(EventSource.sole).to have_attributes(status: "idle", enabled: true)
    end

    it "spends exactly two Search requests, split one per lane" do
      expect(current_search_budget).to have_attributes(used: 2, actor_used: 1, repository_used: 1)
    end

    it "spends exactly two core detail requests of the bounded fallback allowance" do
      expect(current_budget).to have_attributes(
        poll_used: 1, enrichment_used: 2, actor_share_used: 1, repository_share_used: 1
      )
    end

    it "retains one batch row per request, with the miss counted where it happened" do
      search = EnrichmentBatch.where(request_kind: "search").order(:id)
      detail = EnrichmentBatch.where(request_kind: "detail").order(:id)

      expect(search.pluck(:entity_kind, :status, :requested_count, :returned_count,
                          :valid_count, :missing_count))
        .to eq([ [ "actor", "succeeded", 3, 2, 2, 1 ],
                 [ "repository", "succeeded", 3, 2, 2, 1 ] ])
      expect(detail.pluck(:entity_kind, :status, :response_status))
        .to contain_exactly([ "actor", "failed", 404 ], [ "repository", "failed", 404 ])
    end

    it "keeps the observation ledger complete: event pairs plus applied search items" do
      expect(EnrichmentObservation.where(source: "event").count).to eq(8)
      expect(EnrichmentObservation.where(source: "search").pluck(:validation_outcome).uniq)
        .to eq([ "applied" ])
      expect(EnrichmentObservation.where(source: "search").pluck(:requested_identifier))
        .to contain_exactly("octocat", "monalisa", "octocat/Hello-World", "monalisa/Spoon-Knife")
    end

    # §7 and ADR 0001: raw retention is semantic, not byte-exact — jsonb preserves
    # neither whitespace nor key order. The staged pipeline retains the *Search item*.
    it "retains each applied document as jsonb, content-equivalent to the corpus item" do
      body = JSON.parse(Rails.root.join("fixtures/github/bodies/search/users-partial.json").read)
      octocat_item = body.fetch("items").find { _1.fetch("id") == 583_231 }

      expect(GithubActor.find_by(github_id: 583_231).raw_payload).to eq(octocat_item)
    end

    # §7 is explicit that the envelope's repo.name is the qualified form and "is **not**
    # silently equated with the enriched name". Both columns are envelope-owned.
    it "leaves the repository name envelope-derived, which enrichment must never overwrite" do
      expect(GithubRepository.find_by(github_id: 1_296_269))
        .to have_attributes(name: "Hello-World", full_name: "octocat/Hello-World")
    end

    it "tells the whole story in one cycle's counters" do
      expect(@cycle).to have_attributes(
        batches_attempted: 2, batches_completed: 2, items_requested: 6, items_valid: 4,
        fallbacks_admitted: 2, details_attempted: 2, details_completed: 0,
        details_terminal: 2, batch_stop_reason: "no_batch_work",
        detail_stop_reason: "no_detail_work"
      )
    end

    it "issues exactly five offline requests, in staged order, and no network request" do
      expect(transport.requests.map { _1.fetch(:key) }).to eq([
        "/events?per_page=100",
        "/search/users?per_page=3&q=user%3Aoctocat+user%3Amonalisa+user%3Aghostuser",
        "/search/repositories?per_page=3&q=repo%3Aoctocat%2FHello-World+repo%3Amonalisa%2FSpoon-Knife+repo%3Adeleted-org%2Fgone",
        "/users/ghostuser",
        "/repos/deleted-org/gone"
      ])
      expect(WebMock).not_to have_requested(:any, //)
    end
  end

  describe "the cycle after the cycle" do
    before do
      ingest!
      run_cycle!
    end

    # Complete rows are fresh, terminal rows are decided: neither lane has claimable
    # work, so the second cycle spends nothing at all.
    it "finds nothing to do and spends nothing" do
      second = run_cycle!

      expect(second).to have_attributes(batches_attempted: 0, details_attempted: 0,
                                        batch_stop_reason: "no_batch_work",
                                        detail_stop_reason: "no_detail_work")
      expect(current_search_budget.used).to eq(2)
      expect(current_budget.enrichment_used).to eq(2)
    end
  end

  describe "durable backlog across quota windows" do
    let(:actor) { GithubActor.find_by(github_id: 583_231) }

    before { ingest! }

    # The admission pre-check is what stops the cycle here: a denied tick claims no
    # rows, creates no batch row, and spends nothing — churn control, not just budget
    # control.
    it "defers without touching the staged rows when the search window is exhausted" do
      active_search_window(now: now, used: 8)
      before_rows = GithubActor.order(:id).map(&:attributes)

      cycle = run_cycle!

      expect(cycle.batch_stop_reason).to eq("search_ceiling_exhausted")
      expect(GithubActor.order(:id).map(&:attributes)).to eq(before_rows)
      expect(EnrichmentBatch.count).to eq(0)
    end

    it "eventually completes work that waited beyond one search window" do
      active_search_window(now: now, used: 8)
      expect(run_cycle!.batches_completed).to eq(0)

      # Sixty-one seconds later the ledger rolls the minute window on its next
      # reservation, and the durable FIFO resumes exactly where it stopped.
      cycle = run_cycle!(at: now + 61)

      expect(cycle.batches_completed).to eq(2)
      expect(actor.reload).to have_attributes(enrichment_status: "complete",
                                              enrichment_stage: "contract_complete")
    end
  end

  # §12: "Poll allowance protected from enrichment demand — and vice versa (class-blocking
  # isolation: one class exhausted, the other proceeds)."
  describe "class isolation between polling and the staged lanes" do
    it "still polls when the core detail allowance is spent" do
      ingest!
      GithubApiBudget.where(id: GithubApiBudget::SINGLETON_ID).update_all(enrichment_used: 4)

      # A 304 is a poll that happened — §10 keeps its reservation debited — so the
      # assertion is that nothing deferred it, not which body came back.
      expect(fixture_runner(transport: transport, now: now + 120)
        .call(event_source: EventSource.sole, force: true)).not_to be_deferred
      expect(current_budget.poll_used).to eq(2)
    end

    it "still runs Search batches when polling has spent its whole allowance" do
      ingest!
      GithubApiBudget.where(id: GithubApiBudget::SINGLETON_ID).update_all(poll_used: 12)

      cycle = run_cycle!

      expect(cycle.batches_completed).to eq(2)
      expect(current_search_budget.used).to eq(2)
    end
  end
end
