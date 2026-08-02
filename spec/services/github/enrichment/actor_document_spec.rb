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

  describe "the useful-data contract" do
    it "populates account_type and the whole document, which is all the contract assigns" do
      document = described_class.parse(body, github_id: github_id)

      expect(document).to be_ok
      expect(document.attributes[:account_type]).to eq("User")
      expect(document.attributes[:raw_payload]).to include("login" => "octocat", "id" => github_id)
    end

    # login, display_login, api_url and avatar_url are envelope-owned:
    # GithubActor::IDENTITY_MERGE is their only writer, and §7 keeps the envelope shape and
    # the enriched document shape explicitly distinct.
    it "never writes login or avatar_url, which the envelope owns" do
      document = described_class.parse(body, github_id: github_id)

      expect(document.attributes.keys).to contain_exactly(:account_type, :raw_payload)
    end

    # raw_payload is the full item, always: whatever a projection ignores today, the
    # enriched truth is preserved verbatim for a later reading.
    it "keeps unknown fields in the payload without mapping them to columns" do
      document = parse({ "id" => github_id, "type" => "User", "invented_field" => true })

      expect(document.attributes[:raw_payload]).to include("invented_field" => true)
      expect(document.attributes.keys).to contain_exactly(:account_type, :raw_payload)
    end
  end

  # `type` is a contract field, not an optional one: a Search item that cannot say whether
  # the account is a User or an Organization has not satisfied the useful-data contract,
  # and the row goes to the bounded detail fallback rather than being marked complete.
  describe "the type contract" do
    it "refuses a document with no type at all" do
      document = parse({ "id" => github_id })

      expect(document).not_to be_ok
      expect(document.error_code).to eq("invalid_contract_field")
      expect(document.error_message).to include("type")
    end

    it "refuses a blank type rather than storing an empty string" do
      expect(parse({ "id" => github_id, "type" => "  " }).error_code).to eq("invalid_contract_field")
      expect(parse({ "id" => github_id, "type" => "" }).error_code).to eq("invalid_contract_field")
    end

    it "refuses a non-String type rather than coercing it" do
      expect(parse({ "id" => github_id, "type" => 42 }).error_code).to eq("invalid_contract_field")
      expect(parse({ "id" => github_id, "type" => nil }).error_code).to eq("invalid_contract_field")
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
      expect(parse({ "login" => "octocat", "type" => "User" }).error_code).to eq("missing_identity")
      expect(parse({ "id" => "583231", "type" => "User" }).error_code).to eq("missing_identity")
    end

    # GitHub logins are recyclable, so a stale actor.url can legitimately resolve to a
    # different person. Writing that document into this row would corrupt the identity join
    # push_events.github_actor_id still relies on, which is why it gets its own kind rather
    # than being folded into "malformed".
    it "refuses another entity's document under its own error code" do
      document = parse({ "id" => 999, "type" => "User" })

      expect(document.kind).to eq(:identity_mismatch)
      expect(document.error_message).to include("999", "583231")
    end
  end
end
