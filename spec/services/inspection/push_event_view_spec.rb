require "rails_helper"

RSpec.describe Inspection::PushEventView do
  let(:actor) { create_actor(github_id: 1001) }
  let(:repository) { create_repository(github_id: 2001) }
  let(:event) { create_push_event(actor: actor, repository: repository) }

  describe ".summary" do
    it "identifies the event by the id §11 puts on every log line" do
      expect(described_class.summary(event)).to include(id: event.github_event_id)
    end

    # The surrogate primary key is not this application's identity vocabulary — even the
    # foreign keys target github_id — and it survives only inside the opaque cursor.
    it "exposes the surrogate primary key nowhere" do
      expect(described_class.summary(event)).not_to have_key(:record_id)
      expect(described_class.summary(event).values).not_to include(event.id)
    end

    # push_events.raw_payload is jsonb NOT NULL holding a whole GitHub envelope, deliberately
    # un-indexed and almost always TOASTed. A page of them is two orders of magnitude larger
    # than the fields anyone reads in a list.
    it "keeps the TOASTed payload out of the list shape" do
      expect(described_class.summary(event)).not_to have_key(:raw_payload)
    end

    # The gap between the two is the ingestion latency §11 otherwise exposes only in logs.
    it "reports GitHub's clock and this application's separately" do
      expect(described_class.summary(event))
        .to include(occurred_at: event.occurred_at.utc.iso8601,
                    ingested_at: event.created_at.utc.iso8601)
    end

    it "nests both entities with the enrichment state a reviewer watches flip" do
      actor.update!(enrichment_status: "complete", fetched_at: frozen_time, name: "The Octocat")

      summary = described_class.summary(event)

      expect(summary[:actor]).to include(github_id: 1001, login: "octocat",
                                         name: "The Octocat",
                                         enrichment_status: "complete",
                                         fetched_at: frozen_time.utc.iso8601)
      expect(summary[:repository]).to include(github_id: 2001,
                                              full_name: "octocat/hello-world",
                                              enrichment_status: "pending",
                                              fetched_at: nil)
    end

    # A log line drops nil keys because an absent field is noise. A response body must not:
    # "name": null means "not enriched yet", which is information, and a key that appears
    # and disappears makes every client handle two shapes for one resource.
    it "keeps its key set stable whether or not the entities are enriched" do
      unenriched = described_class.summary(event)
      actor.update!(enrichment_status: "complete", fetched_at: frozen_time, name: "x")
      repository.update!(enrichment_status: "complete", fetched_at: frozen_time,
                         description: "y", language: "Ruby")

      enriched = described_class.summary(event.reload)

      expect(enriched.keys).to eq(unenriched.keys)
      expect(enriched[:actor].keys).to eq(unenriched[:actor].keys)
      expect(enriched[:repository].keys).to eq(unenriched[:repository].keys)
    end

    # last_error can hold a fetch error's message verbatim, and HealthController already
    # establishes that internals do not cross the HTTP boundary. §11 assigns the aggregate
    # view of retry state to /status.
    it "leaks no per-entity retry diagnostics" do
      summary = described_class.summary(event)

      expect(summary[:actor].keys)
        .not_to include(:last_error, :next_retry_at, :enrichment_attempts, :raw_payload)
    end
  end

  describe ".detail" do
    # §16 makes "raw payload is retained" a functional gate, and this is what makes it
    # demonstrable without a psql session.
    it "is the list shape plus the retained payload" do
      detail = described_class.detail(event)

      expect(detail.except(:raw_payload)).to eq(described_class.summary(event))
      expect(detail[:raw_payload]).to eq(event.raw_payload)
    end
  end

  describe ".page" do
    it "wraps the rows and reports the paging position beside them" do
      event
      rendered = described_class.page(Inspection::PushEventPage.for(limit: "1"))

      expect(rendered.keys).to eq(%i[data pagination])
      expect(rendered[:data].map { |row| row[:id] }).to eq([ event.github_event_id ])
      expect(rendered[:pagination]).to eq(limit: 1, count: 1, next_cursor: nil)
    end

    it "hands back the cursor that reaches the next page" do
      event
      create_push_event(actor: actor, repository: repository,
                        github_event_id: "40000000002", occurred_at: frozen_time - 60)

      rendered = described_class.page(Inspection::PushEventPage.for(limit: "1"))

      expect(rendered[:pagination][:next_cursor]).to be_a(String)
    end
  end
end
