require "rails_helper"

# Appendix G's fairness at the level that actually schedules work: CycleRunner's
# weighted LaneSchedule over real FOR UPDATE SKIP LOCKED claims and both real ledgers,
# with WebMock echoing every Search qualifier back as a validating item so the whole
# Faraday request stack runs offline.
#
# The property under test is the same one §12 stated for the per-entity design — a
# one-sided flood cannot starve the other class, and an idle lane's slots are borrowed
# rather than wasted — restated for batches and for the bounded core detail lane.
RSpec.describe "lane fairness across the weighted schedule", type: :integration do
  let(:now) { frozen_time }
  let(:clock) { -> { now } }

  def build_cycle_runner(configuration)
    executor = Github::RequestExecutor.new(
      transport: Github::Transports::Faraday.new,
      ledger: ledger_for(configuration),
      search_ledger: search_ledger_for(configuration),
      mode: :live, sleeper: ->(_seconds) { }, clock: clock
    )

    Github::Enrichment::CycleRunner.new(
      configuration: configuration,
      batch_runner: Github::Enrichment::BatchRunner.new(
        executor: executor, configuration: configuration,
        claim: Github::Enrichment::BatchClaim.new(configuration: configuration),
        search_ledger: search_ledger_for(configuration),
        backoff: jitterless_backoff(configuration: configuration), clock: clock
      ),
      detail_runner: Github::Enrichment::DetailRunner.new(
        executor: executor, configuration: configuration,
        claim: Github::Enrichment::DetailClaim.new(configuration: configuration),
        backoff: jitterless_backoff(configuration: configuration), clock: clock
      ),
      admission: Github::Enrichment::Admission.new(configuration: configuration),
      batch_claim: Github::Enrichment::BatchClaim.new(configuration: configuration),
      detail_claim: Github::Enrichment::DetailClaim.new(configuration: configuration),
      clock: clock, sleeper: ->(_seconds) { }
    )
  end

  # Echoes every requested qualifier back as a validating item, and records which lane
  # each Search request served so the schedule's interleaving is assertable.
  def stub_search_echo!(search_lanes)
    stub_request(:get, %r{\Ahttps://api\.github\.com/search/(users|repositories)\?})
      .to_return do |request|
        query = URI.decode_www_form(request.uri.query.to_s).to_h
        identifiers = query.fetch("q").split(" ").map { |qualifier| qualifier.split(":", 2).last }
        actor = request.uri.path.end_with?("/users")
        search_lanes << (actor ? :actor : :repository)

        items = identifiers.map do |identifier|
          github_id = identifier[/(\d+)\z/, 1].to_i
          actor ? { "id" => github_id, "login" => identifier, "type" => "User" }
                : repository_item(github_id, identifier)
        end

        {
          status: 200,
          headers: {
            "Content-Type" => "application/json",
            "X-RateLimit-Resource" => "search", "X-RateLimit-Limit" => "10",
            "X-RateLimit-Remaining" => (10 - current_search_budget.used).to_s,
            "X-RateLimit-Reset" => (now + 60).to_i.to_s
          },
          body: JSON.generate(
            "total_count" => items.length, "incomplete_results" => false, "items" => items
          )
        }
      end
  end

  def repository_item(github_id, full_name)
    {
      "id" => github_id, "full_name" => full_name,
      "owner" => { "id" => github_id + 100_000, "login" => full_name.split("/").first },
      "fork" => false, "archived" => false, "default_branch" => "main",
      "description" => "Fairness repository #{github_id}", "language" => "Ruby",
      "created_at" => "2026-07-01T00:00:00Z"
    }
  end

  def create_flood_actor(github_id, index)
    create_actor(
      github_id: github_id, login: "fair-user-#{github_id}",
      display_login: "fair-user-#{github_id}",
      api_url: "https://api.github.com/users/fair-user-#{github_id}",
      created_at: now - 1000 + index, updated_at: now
    )
  end

  def create_flood_repository(github_id, index)
    create_repository(
      github_id: github_id, full_name: "fair/repo-#{github_id}", name: "repo-#{github_id}",
      api_url: "https://api.github.com/repos/fair/repo-#{github_id}",
      created_at: now - 1000 + index, updated_at: now
    )
  end

  describe "a twenty-to-one repository flood against equal weights" do
    let(:configuration) { configuration_with("SEARCH_PACING_SECONDS" => "0") }
    let(:actor_ids) { [ 30_001 ] }
    let(:repository_ids) { (40_001..40_020).to_a }

    before do
      active_budget_window(now: now)
      actor_ids.each_with_index { |github_id, index| create_flood_actor(github_id, index) }
      repository_ids.each_with_index { |github_id, index| create_flood_repository(github_id, index) }
    end

    it "serves the starved lane first, then hands its idle slots to the flood" do
      search_lanes = []
      stub_search_echo!(search_lanes)

      cycle = build_cycle_runner(configuration).call

      # Rotation actor→repository at weight 1:1: the single actor rides slot one, the
      # flood takes slot two, and slot three — scheduled for the now-empty actor
      # lane — is borrowed by the repository backlog rather than wasted.
      expect(search_lanes).to eq(%i[actor repository repository])
      expect(cycle).to have_attributes(batches_attempted: 3, batches_completed: 3,
                                       items_requested: 21, items_valid: 21,
                                       batch_stop_reason: "no_batch_work")
    end

    it "records the split on the search ledger's per-lane counters" do
      stub_search_echo!([])

      build_cycle_runner(configuration).call

      expect(current_search_budget).to have_attributes(used: 3, actor_used: 1, repository_used: 2)
      expect(EnrichmentBatch.where(request_kind: "search").group(:entity_kind).count)
        .to eq("actor" => 1, "repository" => 2)
    end

    it "completes every row in both classes — the flood starved nothing" do
      stub_search_echo!([])

      build_cycle_runner(configuration).call

      expect(GithubActor.distinct.pluck(:enrichment_stage)).to eq([ "contract_complete" ])
      expect(GithubRepository.distinct.pluck(:enrichment_stage)).to eq([ "contract_complete" ])
    end
  end

  describe "a two-to-one repository weight over deep backlogs" do
    # Ceiling 8 with the default reserve of 2 makes six spendable requests — two full
    # a,r,r rotations — while the echoed x-ratelimit-remaining (10 - used = 4) stays
    # above the reserve, so the ceiling and not a header block is what ends the window.
    let(:configuration) do
      configuration_with("SEARCH_PACING_SECONDS" => "0", "SEARCH_REQUEST_CEILING" => "8",
                         "REPOSITORY_ENRICHMENT_WEIGHT" => "2")
    end

    before do
      active_budget_window(now: now)
      (50_001..50_030).each_with_index { |github_id, index| create_flood_actor(github_id, index) }
      (60_001..60_050).each_with_index { |github_id, index| create_flood_repository(github_id, index) }
    end

    # Both lanes stay claimable for the whole window, so the six spendable requests
    # land exactly as the a,r,r rotation dictates — the weights, not the backlog
    # depths, decide the split.
    it "divides the window's requests by the configured weights" do
      search_lanes = []
      stub_search_echo!(search_lanes)

      cycle = build_cycle_runner(configuration).call

      expect(search_lanes).to eq(%i[actor repository repository actor repository repository])
      expect(current_search_budget).to have_attributes(used: 6, actor_used: 2, repository_used: 4)
      expect(cycle.batch_stop_reason).to eq("search_ceiling_exhausted")
    end

    it "preserves the untaken remainder of both FIFOs for the next window" do
      stub_search_echo!([])

      build_cycle_runner(configuration).call

      expect(GithubActor.where(enrichment_stage: "batch_pending").order(:created_at, :id).pluck(:github_id))
        .to eq((50_021..50_030).to_a)
      expect(GithubRepository.where(enrichment_stage: "batch_pending").count).to eq(10)
    end
  end

  describe "the bounded detail lane borrowing the idle class's slots" do
    let(:configuration) { configuration_with("SEARCH_PACING_SECONDS" => "0") }
    let(:repository_ids) { (70_001..70_003).to_a }

    before do
      active_budget_window(now: now)
      repository_ids.each_with_index { |github_id, index| create_flood_repository(github_id, index) }
      GithubRepository.where(github_id: repository_ids).update_all(
        enrichment_stage: "detail_pending", detail_pending_at: now, updated_at: now
      )

      stub_request(:get, %r{\Ahttps://api\.github\.com/repos/fair/repo-\d+\z})
        .to_return do |request|
          github_id = request.uri.path[/-(\d+)\z/, 1].to_i
          {
            status: 200,
            headers: {
              "Content-Type" => "application/json",
              "X-RateLimit-Resource" => "core", "X-RateLimit-Limit" => "60",
              "X-RateLimit-Remaining" => "50",
              "X-RateLimit-Reset" => current_budget.reset_at.to_i.to_s
            },
            body: JSON.generate(repository_item(github_id, "fair/repo-#{github_id}"))
          }
        end
    end

    # The repository guarantee is 2 of the 4-request core detail allowance. The third
    # completion is only reachable because the scheduled actor slot had no candidate
    # and the borrow flag travelled to the core ledger — §10's borrowing, exercised
    # end to end through the CycleRunner rather than asserted on a unit.
    it "lets the flooded class spend past its guarantee on the idle lane's slots" do
      cycle = build_cycle_runner(configuration).call

      expect(cycle).to have_attributes(details_attempted: 3, details_completed: 3,
                                       detail_stop_reason: "no_detail_work")
      expect(current_budget).to have_attributes(
        enrichment_used: 3, actor_share_used: 0, repository_share_used: 3
      )
      expect(GithubRepository.distinct.pluck(:enrichment_stage)).to eq([ "contract_complete" ])
    end
  end
end
