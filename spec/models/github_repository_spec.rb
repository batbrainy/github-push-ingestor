require "rails_helper"

RSpec.describe GithubRepository do
  let(:valid_attributes) { repository_attributes }

  it_behaves_like "an enrichable entity"

  describe ".upsert_stub!" do
    # Plan §7: the envelope's repo.name is the qualified owner/repository form and maps
    # to full_name. It is deliberately not equated with the enriched short name.
    it "maps the envelope's qualified name to full_name" do
      id = described_class.upsert_stub!(
        github_id: 8484,
        full_name: "octocat/hello-world",
        name: "hello-world",
        api_url: "https://api.github.com/repos/octocat/hello-world",
        now: frozen_time
      )

      repository = described_class.find(id)
      expect(repository.full_name).to eq("octocat/hello-world")
      expect(repository.name).to eq("hello-world")
      expect(repository.enrichment_status).to eq("pending")
    end

    it "leaves name null when the envelope has not supplied one" do
      id = described_class.upsert_stub!(github_id: 8484, full_name: "octocat/hello-world",
                                       now: frozen_time)

      expect(described_class.find(id).name).to be_nil
    end

    it "refreshes full_name on a later observation" do
      described_class.upsert_stub!(github_id: 8484, full_name: "octocat/hello-world",
                                   now: frozen_time)
      described_class.upsert_stub!(github_id: 8484, full_name: "octocat/renamed",
                                   now: frozen_time + 60)

      expect(described_class.find_by(github_id: 8484).full_name).to eq("octocat/renamed")
      expect(described_class.count).to eq(1)
    end

    it "does not blank a known name when the envelope omits it" do
      described_class.upsert_stub!(github_id: 8484, full_name: "octocat/hello-world",
                                   name: "hello-world", now: frozen_time)
      described_class.upsert_stub!(github_id: 8484, full_name: "octocat/hello-world",
                                   now: frozen_time + 60)

      expect(described_class.find_by(github_id: 8484).name).to eq("hello-world")
    end

    it "never regresses updated_at for a late-arriving envelope" do
      described_class.upsert_stub!(github_id: 8484, full_name: "octocat/hello-world",
                                   now: frozen_time + 300)
      described_class.upsert_stub!(github_id: 8484, full_name: "octocat/hello-world",
                                   now: frozen_time)

      expect(described_class.find_by(github_id: 8484).updated_at).to eq(frozen_time + 300)
    end

    it "refuses a malformed envelope before reaching the database" do
      expect { described_class.upsert_stub!(github_id: nil, full_name: "octocat/hello") }
        .to raise_error(ActiveRecord::RecordInvalid)

      expect { described_class.upsert_stub!(github_id: 8484, full_name: nil) }
        .to raise_error(ActiveRecord::RecordInvalid)

      expect(described_class.count).to eq(0)
    end

    it "never clears enrichment-owned fields" do
      described_class.upsert_stub!(github_id: 8484, full_name: "octocat/hello-world",
                                   now: frozen_time)
      described_class.find_by(github_id: 8484).update_columns(
        description: "My first repository",
        language: "Ruby",
        owner_github_id: 1,
        raw_payload: { "full_name" => "octocat/hello-world" },
        enrichment_status: "complete",
        fetched_at: frozen_time
      )

      described_class.upsert_stub!(github_id: 8484, full_name: "octocat/hello-world",
                                   now: frozen_time + 60)

      repository = described_class.find_by(github_id: 8484)
      expect(repository.description).to eq("My first repository")
      expect(repository.language).to eq("Ruby")
      expect(repository.owner_github_id).to eq(1)
      expect(repository.raw_payload).to eq("full_name" => "octocat/hello-world")
      expect(repository.enrichment_status).to eq("complete")
    end

    it "leaves a budget-skipped entity skipped, with its failure state intact" do
      described_class.upsert_stub!(github_id: 8484, full_name: "octocat/hello-world",
                                   now: frozen_time)
      described_class.where(github_id: 8484).update_all(
        enrichment_status: "skipped_budget",
        skipped_at: frozen_time,
        enrichment_attempts: 2,
        next_retry_at: frozen_time + 3600,
        last_error: "enrichment allowance exhausted"
      )

      described_class.upsert_stub!(github_id: 8484, full_name: "octocat/renamed",
                                   now: frozen_time + 60)

      repository = described_class.find_by(github_id: 8484)
      expect(repository.full_name).to eq("octocat/renamed")
      expect(repository.enrichment_status).to eq("skipped_budget")
      expect(repository.skipped_at).to eq(frozen_time)
      expect(repository.enrichment_attempts).to eq(2)
      expect(repository.last_error).to eq("enrichment allowance exhausted")
    end
  end

  describe "database constraints" do
    it "rejects a duplicate github_id" do
      create_repository(github_id: 8484)

      expect_violation(ActiveRecord::RecordNotUnique) do
        described_class.insert!(repository_attributes(github_id: 8484))
      end
    end

    it "requires github_id and full_name" do
      %i[github_id full_name].each do |column|
        expect_violation(ActiveRecord::NotNullViolation) do
          described_class.insert!(repository_attributes.except(column))
        end
      end
    end
  end
end
