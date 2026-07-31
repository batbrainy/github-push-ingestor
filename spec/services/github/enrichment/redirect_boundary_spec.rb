require "rails_helper"

# The corpus has carried `redirecting_repository` and `hostile_redirect` since PR 4, and
# until now nothing consumed them: fixtures/github/README.md said "the redirect ones wait for
# PR 11", and the only reference anywhere was a spec asserting the scenario *names* exist.
# §16's final-review gate forbids dead infrastructure, and corpus that exists only to be
# enumerated is exactly that.
#
# spec/services/github/request_executor_spec.rb already covers the redirect machinery at the
# executor level — following a validated target, debiting each hop, refusing an off-host
# Location, stopping at MAX_REDIRECTS. What it cannot show is the consequence for an
# *entity*, because the executor has no entity: whether a rename lands as `complete`, whether
# a hostile hop costs the entity its record, and — the one §10 cares about most — whether
# either of them can take the event source out of service. That is this file.
#
# Both scenarios are single-hop, so MAX_REDIRECTS stays at its default of 2 and nothing is
# added to the compose anchor to run them.
RSpec.describe "enrichment across a redirect", type: :integration do
  # The corpus body for this id is repos/octocat_hello-world.json, whose own `id` is
  # 1296269 — RepositoryDocument.parse checks identity, so the row and the body have to
  # agree or a rename would be indistinguishable from a mis-served body.
  let!(:repository) do
    create_repository(github_id: IngestionHelpers::REPOSITORY_GITHUB_ID,
                      full_name: "octocat/Hello-World", name: "Hello-World",
                      api_url: "https://api.github.com/repos/octocat/Hello-World",
                      last_seen_at: frozen_time, enrichment_status: "pending")
  end

  let!(:event_source) { fixture_event_source }

  before { active_budget_window(now: frozen_time) }

  # --class repository, because fairness picks actor before repository as its tie-break and
  # an unscoped cycle would not reliably reach this row. Narrowing the class bypasses no
  # budget rule — the allowance, the share, the reserve and every global block still bind.
  def enrich(scenario)
    transport = fixture_transport(scenario: scenario)
    result = fixture_enrichment_runner(transport: transport).call(entity_class: GithubRepository)

    [ result, transport ]
  end

  describe "redirecting_repository — a rename the URL policy accepts" do
    it "follows the hop and completes the entity" do
      result, = enrich("redirecting_repository")

      expect(result).to be_enriched
      expect(repository.reload.enrichment_status).to eq("complete")
    end

    it "stores the document the second hop returned" do
      enrich("redirecting_repository")

      expect(repository.reload.full_name).to eq("octocat/Hello-World")
      expect(repository.reload.fetched_at).to be_present
    end

    # §7's "failures stay spent" generalizes to hops: each one is a real outbound request
    # and the ledger debits every attempt. Two requests for one entity is the honest cost of
    # a rename, and an operator reading the per-class counter should see it.
    it "charges the repository share for both hops, not one" do
      _, transport = enrich("redirecting_repository")

      expect(transport.requests.size).to eq(2)
      expect(current_budget.repository_share_used).to eq(2)
      expect(current_budget.enrichment_used).to eq(2)
    end

    it "leaves no lease behind on the completed entity" do
      enrich("redirecting_repository")

      expect(repository.reload.next_retry_at).to be_nil
    end
  end

  describe "hostile_redirect — a Location pointing off-host" do
    it "refuses the entity rather than following it" do
      result, = enrich("hostile_redirect")

      expect(result).to be_failed
      expect(repository.reload.enrichment_status).to eq("permanent_failure")
    end

    # The assertion that makes this an SSRF test rather than an error-handling test: the
    # second hop was never sent. The URL policy runs *before* the request gate, so the
    # refusal happens outside any reservation and the socket is never opened.
    it "never sends the second request" do
      _, transport = enrich("hostile_redirect")

      expect(transport.requests.size).to eq(1)
      expect(transport.requests.map(&:to_s)).to all(include("api.github.com"))
    end

    it "spends one debit — the hop that did happen — and no more" do
      enrich("hostile_redirect")

      expect(current_budget.repository_share_used).to eq(1)
      expect(current_budget.enrichment_used).to eq(1)
    end

    it "records the policy violation on the entity so an operator sees the reason" do
      enrich("hostile_redirect")

      expect(repository.reload.last_error).to be_present
    end

    # §10's rule, and the one a hostile payload would otherwise be able to exploit: a
    # redirect target this application refuses is a fact about one entity, never about the
    # feed. Taking the source out of service on it would let one crafted repository URL stop
    # ingestion for everything.
    it "never takes the event source out of service" do
      enrich("hostile_redirect")

      expect(event_source.reload.status).to eq("idle")
      expect(event_source.reload.enabled).to be(true)
      expect(event_source.reload.consecutive_failures).to eq(0)
    end

    it "writes no global block, because one bad target is not a rate limit" do
      enrich("hostile_redirect")

      expect(current_budget.global_blocked_until).to be_nil
      expect(current_budget.window_status).to eq("active")
    end
  end
end
