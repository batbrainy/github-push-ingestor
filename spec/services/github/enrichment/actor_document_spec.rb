require "rails_helper"

RSpec.describe Github::Enrichment::ActorDocument do
  # The corpus body the fixture transport actually serves for /users/octocat, so the
  # mapping is asserted against the shape enrichment really receives rather than a
  # hand-written stand-in.
  let(:body) { File.read(Rails.root.join("fixtures/github/bodies/users/octocat.json")) }
  let(:github_id) { 583_231 }

  def parse(document, id: github_id)
    described_class.parse(document.is_a?(String) ? document : JSON.generate(document), github_id: id)
  end

  describe "the §7 mapping" do
    it "populates name and the whole document, which is all §7 assigns to enrichment" do
      document = described_class.parse(body, github_id: github_id)

      expect(document).to be_ok
      expect(document.attributes[:name]).to eq("The Octocat")
      expect(document.attributes[:raw_payload]).to include("login" => "octocat", "id" => github_id)
    end

    # login, display_login, api_url and avatar_url are envelope-owned:
    # GithubActor::IDENTITY_MERGE is their only writer, and §7 keeps the envelope shape and
    # the enriched document shape explicitly distinct.
    it "never writes login or avatar_url, which the envelope owns" do
      document = described_class.parse(body, github_id: github_id)

      expect(document.attributes.keys).to contain_exactly(:name, :raw_payload)
    end

    it "keeps unknown fields in the payload without mapping them to columns" do
      document = parse({ "id" => github_id, "name" => "Octo", "invented_field" => true })

      expect(document.attributes[:raw_payload]).to include("invented_field" => true)
      expect(document.attributes.keys).to contain_exactly(:name, :raw_payload)
    end
  end

  # §7's tolerant-parser doctrine: identity fields are strict, everything else degrades to
  # NULL. Refusing a whole document over an optional field would throw away what did
  # arrive, and a malformed verdict is destructive — it writes permanent_failure.
  describe "tolerance for optional fields" do
    it "stores a null name rather than refusing the document" do
      expect(parse({ "id" => github_id, "name" => nil }).attributes[:name]).to be_nil
    end

    it "stores a null name when the field is absent entirely" do
      expect(parse({ "id" => github_id }).attributes[:name]).to be_nil
    end

    it "degrades a non-String name to null rather than storing a number in a text column" do
      expect(parse({ "id" => github_id, "name" => 42 }).attributes[:name]).to be_nil
    end

    it "treats a blank name as absent" do
      expect(parse({ "id" => github_id, "name" => "  " }).attributes[:name]).to be_nil
    end
  end

  describe "documents it refuses" do
    it "refuses a body that is not JSON at all" do
      document = described_class.parse("<html>502</html>", github_id: github_id)

      expect(document).not_to be_ok
      expect(document.error_code).to eq("unparsable_document")
    end

    it "refuses an empty body, which carries nothing to store" do
      expect(described_class.parse("", github_id: github_id).error_code).to eq("unparsable_document")
    end

    it "refuses a JSON array, because an entity document is an object" do
      expect(described_class.parse("[]", github_id: github_id).error_code).to eq("not_an_object")
    end

    it "refuses a document with no integer id, which cannot prove which row it describes" do
      expect(parse({ "login" => "octocat" }).error_code).to eq("missing_identity")
      expect(parse({ "id" => "583231" }).error_code).to eq("missing_identity")
    end

    # GitHub logins are recyclable, so a stale actor.url can legitimately resolve to a
    # different person. Writing that document into this row would corrupt the identity join
    # push_events.github_actor_id still relies on, which is why it gets its own kind rather
    # than being folded into "malformed".
    it "refuses another entity's document under its own error code" do
      document = parse({ "id" => 999, "name" => "Someone Else" })

      expect(document.kind).to eq(:identity_mismatch)
      expect(document.error_message).to include("999", "583231")
    end
  end
end
