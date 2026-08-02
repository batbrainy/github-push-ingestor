require "rails_helper"

# The corpus has carried `redirecting_repository` and `hostile_redirect` since PR 4; the
# staged pipeline reroutes them through the one path that still follows a stored URL:
# the Search batch reports octocat/Hello-World missing, the row is admitted to the
# bounded core detail-fallback lane, and the detail fetch of its retained payload
# api_url meets the redirect.
#
# spec/services/github/request_executor_spec.rb covers the redirect machinery at the
# executor level — following a validated target, debiting each hop, refusing an off-host
# Location, stopping at MAX_REDIRECTS. What it cannot show is the consequence for an
# *entity*: whether a rename lands as `complete`, whether a hostile hop can cost the
# entity its record, and — the one §10 cares about most — whether either of them can
# take the event source out of service. That is this file.
RSpec.describe "staged enrichment across a redirect", type: :integration do
  let(:now) { frozen_time }
  let(:configuration) { configuration_with("GITHUB_MODE" => "fixture", "SEARCH_PACING_SECONDS" => "0") }

  # The corpus Search key carries exactly this trio in this order, and the corpus body
  # for the redirect target is repos/octocat_hello-world.json, whose own `id` is
  # 1296269 — RepositoryDocument.parse checks identity, so the row and the body have to
  # agree or a rename would be indistinguishable from a mis-served body.
  let!(:repository) do
    create_repository(github_id: 1_296_269, full_name: "octocat/Hello-World",
                      name: "Hello-World",
                      api_url: "https://api.github.com/repos/octocat/Hello-World",
                      last_seen_at: now, created_at: now - 3, updated_at: now)
  end
  let!(:second_repository) do
    create_repository(github_id: 1_300_192, full_name: "monalisa/Spoon-Knife",
                      name: "Spoon-Knife",
                      api_url: "https://api.github.com/repos/monalisa/Spoon-Knife",
                      last_seen_at: now, created_at: now - 2, updated_at: now)
  end
  let!(:third_repository) do
    create_repository(github_id: 1_490_033, full_name: "deleted-org/gone", name: "gone",
                      api_url: "https://api.github.com/repos/deleted-org/gone",
                      last_seen_at: now, created_at: now - 1, updated_at: now)
  end

  let!(:event_source) { fixture_event_source }

  before { active_budget_window(now: now) }

  # The staged route to the redirect: one Search batch (both scenarios' Search body is
  # missing Hello-World, so it and deleted-org/gone fall back), then one detail claim,
  # which FIFO order hands to Hello-World first.
  def admit_and_fetch_detail(transport)
    batch = fixture_batch_runner(transport: transport, configuration: configuration)
            .call(entity_class: GithubRepository)
    expect(batch).to have_attributes(status: "completed", fallback_count: 2)
    expect(repository.reload.enrichment_stage).to eq("detail_pending")

    fixture_detail_runner(transport: transport, configuration: configuration)
      .call(entity_class: GithubRepository)
  end

  describe "redirecting_repository — a rename the URL policy accepts" do
    let(:transport) { fixture_transport(scenario: "redirecting_repository") }

    it "follows the hop and completes the entity" do
      result = admit_and_fetch_detail(transport)

      expect(result).to have_attributes(status: "completed", github_id: 1_296_269)
      expect(repository.reload).to have_attributes(
        enrichment_status: "complete", enrichment_stage: "contract_complete",
        latest_observation_source: "detail"
      )
    end

    it "stores the document the second hop returned" do
      admit_and_fetch_detail(transport)

      body = JSON.parse(Rails.root.join("fixtures/github/bodies/repos/octocat_hello-world.json").read)
      expect(repository.reload.raw_payload).to eq(body)
      expect(repository.reload.fetched_at).to eq(now)
    end

    # §7's "failures stay spent" generalizes to hops: each one is a real outbound
    # request and the core ledger debits every attempt. Two requests for one entity is
    # the honest cost of a rename, and both land on the detail lane's class counter —
    # the Search request that admitted the row spent the *search* ledger, not this one.
    it "charges the core detail lane for both hops, not one" do
      admit_and_fetch_detail(transport)

      expect(current_budget).to have_attributes(enrichment_used: 2, repository_share_used: 2)
      expect(current_search_budget).to have_attributes(used: 1, repository_used: 1)
    end

    it "leaves no lease behind on the completed entity" do
      admit_and_fetch_detail(transport)

      expect(repository.reload).to have_attributes(
        lease_token: nil, leased_until: nil, current_enrichment_batch_id: nil, next_retry_at: nil
      )
    end
  end

  describe "hostile_redirect — a Location pointing off-host" do
    let(:transport) { fixture_transport(scenario: "hostile_redirect") }

    # §10: "Violations mark the entity permanent_failure." A refused redirect target is
    # a property of the stored URL, not a transient condition, so no number of retries
    # could change the answer — and the bounded core detail allowance is too scarce to
    # spend re-refusing the same hop. The refusal terminates on sight.
    def enrich_through_hostile_hop
      admit_and_fetch_detail(transport)
    end

    it "refuses the hop and terminates the entity on sight" do
      result = enrich_through_hostile_hop

      expect(result.status).to eq("terminal")
      expect(repository.reload).to have_attributes(
        enrichment_status: "permanent_failure", enrichment_stage: "terminal",
        terminal_at: now, detail_attempts: 1, next_retry_at: nil
      )
    end

    # The assertion that makes this an SSRF test rather than an error-handling test:
    # the hostile Location was never fetched. The URL policy runs *before* the request
    # gate, so the refusal happens outside any reservation and the socket never opens.
    it "never sends the second request" do
      enrich_through_hostile_hop

      hops = transport.requests.map { _1.fetch(:url) }
      expect(hops).to all(include("api.github.com"))
      expect(hops.grep(/evil/)).to be_empty
    end

    it "spends one core debit — the hop that did happen — and no more" do
      enrich_through_hostile_hop

      # One Search request on the search ledger; one detail attempt, a single debited
      # hop. The refused second hop reserved nothing, because the URL policy runs
      # before the gate.
      expect(current_budget).to have_attributes(enrichment_used: 1, repository_share_used: 1)
      expect(current_search_budget.used).to eq(1)
    end

    it "records the policy violation on the entity so an operator sees the reason" do
      enrich_through_hostile_hop

      expect(repository.reload.last_error).to be_present
    end

    # §10's rule, and the one a hostile payload would otherwise be able to exploit: a
    # redirect target this application refuses is a fact about one entity, never about
    # the feed. Taking the source out of service on it would let one crafted repository
    # URL stop ingestion for everything.
    it "never takes the event source out of service" do
      enrich_through_hostile_hop

      expect(event_source.reload).to have_attributes(status: "idle", enabled: true,
                                                     consecutive_failures: 0)
    end

    it "writes no global block on either ledger, because one bad target is not a rate limit" do
      enrich_through_hostile_hop

      expect(current_budget.global_blocked_until).to be_nil
      expect(current_budget.window_status).to eq("active")
      expect(current_search_budget.blocked_until).to be_nil
    end
  end
end
