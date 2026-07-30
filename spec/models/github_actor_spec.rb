require "rails_helper"

RSpec.describe GithubActor do
  let(:valid_attributes) { actor_attributes }

  it_behaves_like "an enrichable entity"

  describe ".upsert_stub!" do
    it "inserts a stub from envelope fields" do
      id = described_class.upsert_stub!(
        github_id: 4242,
        login: "octocat",
        display_login: "octocat",
        api_url: "https://api.github.com/users/octocat",
        avatar_url: "https://avatars.githubusercontent.com/u/4242",
        now: frozen_time
      )

      actor = described_class.find(id)
      expect(actor.github_id).to eq(4242)
      expect(actor.login).to eq("octocat")
      expect(actor.api_url).to eq("https://api.github.com/users/octocat")
      expect(actor.enrichment_status).to eq("pending")
      expect(actor.name).to be_nil
      expect(actor.raw_payload).to be_nil
    end

    it "refreshes identity fields on a later observation" do
      described_class.upsert_stub!(github_id: 4242, login: "octocat", now: frozen_time)
      described_class.upsert_stub!(github_id: 4242, login: "renamed-octocat",
                                   now: frozen_time + 60)

      expect(described_class.find_by(github_id: 4242).login).to eq("renamed-octocat")
      expect(described_class.count).to eq(1)
    end

    it "does not blank a known field when the envelope omits it" do
      described_class.upsert_stub!(github_id: 4242, login: "octocat",
                                   display_login: "octocat",
                                   avatar_url: "https://avatars.githubusercontent.com/u/4242",
                                   now: frozen_time)

      described_class.upsert_stub!(github_id: 4242, login: "octocat", now: frozen_time + 60)

      actor = described_class.find_by(github_id: 4242)
      expect(actor.avatar_url).to eq("https://avatars.githubusercontent.com/u/4242")
      expect(actor.display_login).to eq("octocat")
    end

    it "never clears an enrichment payload already stored" do
      described_class.upsert_stub!(github_id: 4242, login: "octocat", now: frozen_time)
      described_class.find_by(github_id: 4242).update_columns(
        name: "The Octocat",
        raw_payload: { "login" => "octocat", "name" => "The Octocat" },
        enrichment_status: "complete",
        fetched_at: frozen_time
      )

      described_class.upsert_stub!(github_id: 4242, login: "octocat", now: frozen_time + 60)

      actor = described_class.find_by(github_id: 4242)
      expect(actor.name).to eq("The Octocat")
      expect(actor.raw_payload).to eq("login" => "octocat", "name" => "The Octocat")
      expect(actor.enrichment_status).to eq("complete")
    end

    # Plan §7: a duplicate event replay may refresh harmless identity fields but can
    # never reactivate enrichment, or a re-polled window would resurrect skipped
    # entities with no new activity.
    it "leaves a budget-skipped entity skipped, with its failure state intact" do
      described_class.upsert_stub!(github_id: 4242, login: "octocat", now: frozen_time)
      described_class.where(github_id: 4242).update_all(
        enrichment_status: "skipped_budget",
        skipped_at: frozen_time,
        enrichment_attempts: 3,
        next_retry_at: frozen_time + 3600,
        last_error: "enrichment allowance exhausted"
      )

      described_class.upsert_stub!(github_id: 4242, login: "octocat-renamed",
                                   now: frozen_time + 60)

      actor = described_class.find_by(github_id: 4242)
      expect(actor.login).to eq("octocat-renamed")
      expect(actor.enrichment_status).to eq("skipped_budget")
      expect(actor.skipped_at).to eq(frozen_time)
      expect(actor.enrichment_attempts).to eq(3)
      expect(actor.next_retry_at).to eq(frozen_time + 3600)
      expect(actor.last_error).to eq("enrichment allowance exhausted")
    end

    it "never regresses updated_at for a late-arriving envelope" do
      described_class.upsert_stub!(github_id: 4242, login: "octocat", now: frozen_time + 300)
      described_class.upsert_stub!(github_id: 4242, login: "octocat", now: frozen_time)

      expect(described_class.find_by(github_id: 4242).updated_at).to eq(frozen_time + 300)
    end

    # upsert goes straight to PostgreSQL, so without the guard a malformed envelope would
    # raise NotNullViolation and abort the ingest transaction, taking the rest of the
    # batch with it rather than quarantining one event.
    it "refuses a malformed envelope before reaching the database" do
      expect { described_class.upsert_stub!(github_id: nil, login: "octocat") }
        .to raise_error(ActiveRecord::RecordInvalid)

      expect { described_class.upsert_stub!(github_id: 4242, login: nil) }
        .to raise_error(ActiveRecord::RecordInvalid)

      expect(described_class.count).to eq(0)
    end

    it "does not touch activity fields, which are gated on a newly inserted event" do
      described_class.upsert_stub!(github_id: 4242, login: "octocat", now: frozen_time)
      described_class.upsert_stub!(github_id: 4242, login: "octocat", now: frozen_time + 60)

      actor = described_class.find_by(github_id: 4242)
      expect(actor.first_seen_at).to be_nil
      expect(actor.last_seen_at).to be_nil
      expect(actor.latest_event_at).to be_nil
    end
  end

  describe "database constraints" do
    it "rejects a duplicate github_id" do
      create_actor(github_id: 4242)

      expect_violation(ActiveRecord::RecordNotUnique) do
        described_class.insert!(actor_attributes(github_id: 4242))
      end
    end

    it "requires github_id and login" do
      %i[github_id login].each do |column|
        expect_violation(ActiveRecord::NotNullViolation) do
          described_class.insert!(actor_attributes.except(column))
        end
      end
    end
  end
end
