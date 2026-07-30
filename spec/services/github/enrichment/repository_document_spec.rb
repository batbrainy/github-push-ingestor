require "rails_helper"

RSpec.describe Github::Enrichment::RepositoryDocument do
  let(:body) { File.read(Rails.root.join("fixtures/github/bodies/repos/octocat_hello-world.json")) }
  let(:github_id) { 1_296_269 }

  def parse(document, id: github_id)
    described_class.parse(JSON.generate(document), github_id: id)
  end

  describe "the §7 mapping" do
    it "populates description, language, owner_github_id and the whole document" do
      document = described_class.parse(body, github_id: github_id)

      expect(document).to be_ok
      expect(document.attributes).to include(
        description: "My first repository on GitHub!", language: "Ruby", owner_github_id: 583_231
      )
    end

    # §7 is most explicit about this one: the envelope's repo.name is the qualified
    # owner/repository form and "is **not** silently equated with the enriched name". Both
    # full_name and the final segment it yields are envelope-owned by IDENTITY_MERGE, so
    # writing the API's short name here would put two writers on one column.
    it "never writes name or full_name, which are envelope-derived" do
      document = described_class.parse(body, github_id: github_id)

      expect(document.attributes.keys)
        .to contain_exactly(:description, :language, :owner_github_id, :raw_payload)
    end
  end

  describe "tolerance for optional fields" do
    it "stores a null description and language rather than refusing the document" do
      document = parse({ "id" => github_id, "description" => nil, "language" => nil })

      expect(document).to be_ok
      expect(document.attributes).to include(description: nil, language: nil)
    end

    # owner_github_id is nullable with no foreign key, so a missing owner object is a
    # column that stays NULL rather than a document that is thrown away.
    it "stores a null owner id when the owner object is absent" do
      expect(parse({ "id" => github_id }).attributes[:owner_github_id]).to be_nil
    end

    it "stores a null owner id when the owner is not an object" do
      expect(parse({ "id" => github_id, "owner" => "octocat" }).attributes[:owner_github_id]).to be_nil
    end

    it "stores a null owner id when the owner carries no integer id" do
      expect(parse({ "id" => github_id, "owner" => { "id" => "583231" } }).attributes[:owner_github_id]).to be_nil
    end
  end

  describe "documents it refuses" do
    it "refuses a body that is not JSON at all" do
      expect(described_class.parse("not json", github_id: github_id).error_code).to eq("unparsable_document")
    end

    it "refuses a document with no integer id" do
      expect(parse({ "full_name" => "octocat/Hello-World" }).error_code).to eq("missing_identity")
    end

    # A repository rename is safe — GitHub 301s to the new path and the id is stable, so
    # the redirect the executor follows produces a match. A genuine mismatch means the URL
    # points at a different repository and must never be trusted for this row again.
    it "refuses another repository's document" do
      expect(parse({ "id" => 999 }).kind).to eq(:identity_mismatch)
    end
  end
end
