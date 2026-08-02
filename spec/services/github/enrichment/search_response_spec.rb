require "rails_helper"

RSpec.describe Github::Enrichment::SearchResponse do
  # The envelope GitHub's Search API documents: total_count, incomplete_results, items.
  def envelope(**overrides)
    {
      "total_count" => 2,
      "incomplete_results" => false,
      "items" => [
        { "id" => 583_231, "login" => "octocat" },
        { "id" => 583_232, "login" => "monalisa" }
      ]
    }.merge(overrides.transform_keys(&:to_s))
  end

  describe "a well-formed envelope" do
    it "parses the raw bytes into the three fields the runner applies" do
      response = described_class.parse(JSON.generate(envelope))

      expect(response).to have_attributes(ok: true, total_count: 2,
                                          incomplete_results: false, error_message: nil)
      expect(response).to be_ok
      expect(response.items.map { |item| item["login"] }).to eq(%w[ octocat monalisa ])
    end

    # The runner reads the items from inside its projection transaction; freezing the
    # array makes an accidental in-place mutation a loud TypeError instead of a
    # corrupted batch.
    it "freezes the items" do
      expect(described_class.parse(JSON.generate(envelope)).items).to be_frozen
    end

    it "accepts an already-decoded Hash body without re-parsing" do
      response = described_class.parse(envelope)

      expect(response).to be_ok
      expect(response.total_count).to eq(2)
    end

    it "keeps GitHub's own truncation flag visible" do
      response = described_class.parse(JSON.generate(envelope(incomplete_results: true)))

      expect(response.incomplete_results).to be(true)
    end

    it "parses an empty result set, which is a valid answer and not a failure" do
      response = described_class.parse(JSON.generate(envelope(total_count: 0, items: [])))

      expect(response).to be_ok
      expect(response.items).to eq([])
    end
  end

  # Every malformed shape becomes a failure value rather than an exception: the batch
  # runner records the reason on the batch row and schedules a retry, and a parser that
  # raised would turn a bad response body into a crashed cycle.
  describe "a malformed envelope" do
    def failure_for(body)
      response = described_class.parse(body)
      expect(response).not_to be_ok
      response
    end

    it "rejects a body that is valid JSON but not an object" do
      response = failure_for("[]")

      expect(response.error_message).to eq("Search response is not an object")
    end

    it "rejects items that are not an array" do
      response = failure_for(JSON.generate(envelope(items: { "id" => 583_231 })))

      expect(response.error_message).to eq("Search response items is not an array")
    end

    it "rejects a missing items key the same way" do
      body = envelope.except("items")

      expect(failure_for(JSON.generate(body)).error_message)
        .to eq("Search response items is not an array")
    end

    # "2" would compare and sort like a count right up until arithmetic on it didn't;
    # the contract check refuses the envelope before any item is applied.
    it "rejects a total_count that is not an integer" do
      response = failure_for(JSON.generate(envelope(total_count: "2")))

      expect(response.error_message).to eq("Search response metadata is malformed")
    end

    it "rejects an incomplete_results that is not a boolean" do
      response = failure_for(JSON.generate(envelope(incomplete_results: "false")))

      expect(response.error_message).to eq("Search response metadata is malformed")
    end

    it "turns unparseable bytes into a failure carrying the parser's own message" do
      response = failure_for("{\"total_count\": ")

      expect(response.error_message).to be_present
      expect(response).to have_attributes(total_count: nil, incomplete_results: nil)
    end

    it "leaves a failure with an empty, frozen item list" do
      response = failure_for("not json at all")

      expect(response.items).to eq([])
      expect(response.items).to be_frozen
    end
  end
end
