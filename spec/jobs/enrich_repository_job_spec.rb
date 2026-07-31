require "rails_helper"

RSpec.describe EnrichRepositoryJob do
  it_behaves_like "an enrichment job",
                  entity_class: GithubRepository, entity_type: :repository, log_key: :github_repository_id

  describe "with the real runner in fixture mode", type: :integration do
    before do
      allow(Github).to receive(:configuration).and_return(configuration_with("GITHUB_MODE" => "fixture"))
      allow(Github::EnrichmentRunner).to receive(:new)
        .and_return(fixture_enrichment_runner(transport: fixture_transport, now: frozen_time))

      active_budget_window(now: frozen_time)
      create_repository(github_id: 1_296_269, last_seen_at: frozen_time,
                        api_url: "https://api.github.com/repos/octocat/Hello-World")
    end

    it "enriches one repository and spends one request" do
      described_class.new.perform_now

      expect(GithubRepository.sole).to have_attributes(
        enrichment_status: "complete", description: "My first repository on GitHub!", language: "Ruby"
      )
      expect(current_budget).to have_attributes(enrichment_used: 1, repository_share_used: 1)
    end

    it "leaves actors alone, whatever the fairness policy would have preferred" do
      create_actor(github_id: 583_231, last_seen_at: frozen_time)

      described_class.new.perform_now

      expect(GithubActor.sole.enrichment_status).to eq("pending")
    end
  end
end
