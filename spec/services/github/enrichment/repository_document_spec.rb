require "rails_helper"

RSpec.describe Github::Enrichment::RepositoryDocument do
  let(:body) { File.read(Rails.root.join("fixtures/github/bodies/repos/octocat_hello-world.json")) }
  let(:github_id) { 1_296_269 }

  # A minimal document satisfying every contract field, so each refusal example states
  # only its one deviation.
  def contract_fields
    {
      "id" => github_id,
      "owner" => { "id" => 583_231, "login" => "octocat" },
      "fork" => false,
      "archived" => false,
      "default_branch" => "main",
      "created_at" => "2011-01-26T19:01:12Z"
    }
  end

  def parse(document, id: github_id)
    described_class.parse(JSON.generate(document), github_id: id)
  end

  describe "the useful-data contract" do
    it "projects the contract fields and the whole document from the corpus body" do
      document = described_class.parse(body, github_id: github_id)

      expect(document).to be_ok
      expect(document.attributes).to include(
        description: "My first repository on GitHub!", language: "Ruby",
        owner_github_id: 583_231, owner_login: "octocat",
        fork: false, archived: false, default_branch: "main",
        github_created_at: Time.utc(2011, 1, 26, 19, 1, 12)
      )
      expect(document.attributes[:raw_payload]).to include("full_name" => "octocat/Hello-World")
    end

    # §7 is most explicit about this one: the envelope's repo.name is the qualified
    # owner/repository form and "is **not** silently equated with the enriched name". Both
    # full_name and the final segment it yields are envelope-owned by IDENTITY_MERGE, so
    # writing the API's short name here would put two writers on one column.
    it "never writes name or full_name, which are envelope-derived" do
      document = described_class.parse(body, github_id: github_id)

      expect(document.attributes.keys).to contain_exactly(
        :description, :language, :owner_github_id, :owner_login, :fork, :archived,
        :default_branch, :github_created_at, :raw_payload
      )
    end

    # Parsed to a UTC instant rather than stored as text: the projection lands in a
    # timestamptz column, and the parse is also the validation.
    it "parses github_created_at to UTC from any ISO-8601 offset" do
      document = parse(contract_fields.merge("created_at" => "2011-01-26T20:01:12+01:00"))

      expect(document).to be_ok
      expect(document.attributes[:github_created_at]).to eq(Time.utc(2011, 1, 26, 19, 1, 12))
    end
  end

  # §7's tolerant-parser doctrine, narrowed by the contract: description and language are
  # genuinely nullable facts about a repository, so NULL is an accepted projection —
  # while the fields the contract names are strict.
  describe "tolerance for nullable fields" do
    it "stores a null description and language rather than refusing the document" do
      document = parse(contract_fields.merge("description" => nil, "language" => nil))

      expect(document).to be_ok
      expect(document.attributes).to include(description: nil, language: nil)
    end

    it "treats a blank description as absent rather than storing an empty string" do
      expect(parse(contract_fields.merge("description" => "")).attributes[:description]).to be_nil
    end

    # owner_login is optional inside a required owner object: the id is the identity the
    # contract needs, the login is a convenience projection.
    it "stores a null owner_login when the owner object omits it" do
      document = parse(contract_fields.merge("owner" => { "id" => 583_231 }))

      expect(document).to be_ok
      expect(document.attributes).to include(owner_github_id: 583_231, owner_login: nil)
    end

    it "degrades a non-String owner_login to null rather than coercing it" do
      document = parse(contract_fields.merge("owner" => { "id" => 583_231, "login" => 42 }))

      expect(document).to be_ok
      expect(document.attributes[:owner_login]).to be_nil
    end
  end

  describe "the contract fields it refuses" do
    it "refuses a missing or non-object owner, whose id the contract requires" do
      expect(parse(contract_fields.except("owner")).error_code).to eq("invalid_contract_field")
      expect(parse(contract_fields.merge("owner" => "octocat")).error_code).to eq("invalid_contract_field")
    end

    it "refuses an owner whose id is not an integer" do
      document = parse(contract_fields.merge("owner" => { "id" => "583231" }))

      expect(document.error_code).to eq("invalid_contract_field")
      expect(document.error_message).to include("owner.id")
    end

    it "refuses a non-boolean fork flag" do
      expect(parse(contract_fields.except("fork")).error_code).to eq("invalid_contract_field")
      expect(parse(contract_fields.merge("fork" => "false")).error_code).to eq("invalid_contract_field")
    end

    it "refuses a non-boolean archived flag" do
      expect(parse(contract_fields.except("archived")).error_code).to eq("invalid_contract_field")
      expect(parse(contract_fields.merge("archived" => 0)).error_code).to eq("invalid_contract_field")
    end

    it "refuses a missing or blank default_branch" do
      expect(parse(contract_fields.except("default_branch")).error_code).to eq("invalid_contract_field")
      expect(parse(contract_fields.merge("default_branch" => " ")).error_code).to eq("invalid_contract_field")
    end

    it "refuses a created_at that is absent or not ISO-8601" do
      expect(parse(contract_fields.except("created_at")).error_code).to eq("invalid_contract_field")
      expect(parse(contract_fields.merge("created_at" => "yesterday")).error_code).to eq("invalid_contract_field")
      expect(parse(contract_fields.merge("created_at" => 1_296_069_672)).error_code).to eq("invalid_contract_field")
    end

    it "refuses a non-String, non-null description rather than guessing at it" do
      expect(parse(contract_fields.merge("description" => 42)).error_code).to eq("invalid_contract_field")
      expect(parse(contract_fields.merge("language" => [ "Ruby" ])).error_code).to eq("invalid_contract_field")
    end
  end

  describe "documents it refuses outright" do
    it "refuses a body that is not JSON at all" do
      expect(described_class.parse("not json", github_id: github_id).error_code).to eq("unparsable_document")
    end

    it "refuses a document with no integer id" do
      expect(parse(contract_fields.except("id")).error_code).to eq("missing_identity")
    end

    # A repository rename is safe — GitHub 301s to the new path and the id is stable, so
    # the redirect the executor follows produces a match. A genuine mismatch means the URL
    # points at a different repository and must never be trusted for this row again.
    it "refuses another repository's document" do
      expect(parse(contract_fields.merge("id" => 999)).kind).to eq(:identity_mismatch)
    end
  end
end
