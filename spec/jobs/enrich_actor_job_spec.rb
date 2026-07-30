require "rails_helper"

RSpec.describe EnrichActorJob do
  it_behaves_like "an enrichment job",
                  entity_class: GithubActor, entity_type: :actor, log_key: :github_actor_id

  # The whole job over the real runner and the offline corpus, so "one cycle" is known to mean
  # one entity and one request rather than only to be stubbed that way.
  describe "with the real runner in fixture mode", type: :integration do
    before do
      allow(Github).to receive(:configuration).and_return(configuration_with("GITHUB_MODE" => "fixture"))
      allow(Github::EnrichmentRunner).to receive(:new)
        .and_return(fixture_enrichment_runner(transport: fixture_transport, now: frozen_time))

      active_budget_window(now: frozen_time)
      create_actor(github_id: 583_231, last_seen_at: frozen_time,
                   api_url: "https://api.github.com/users/octocat")
    end

    it "enriches one actor and spends one request" do
      described_class.new.perform_now

      expect(GithubActor.sole).to have_attributes(enrichment_status: "complete", name: "The Octocat")
      expect(current_budget).to have_attributes(enrichment_used: 1, actor_share_used: 1)
    end

    it "leaves repositories alone, whatever the fairness policy would have preferred" do
      create_repository(github_id: 1_296_269, last_seen_at: frozen_time)

      described_class.new.perform_now

      expect(GithubRepository.sole.enrichment_status).to eq("pending")
    end
  end
end
