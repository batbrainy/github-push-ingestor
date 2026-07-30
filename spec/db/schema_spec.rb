require "rails_helper"

# Guarantees that live in the schema rather than in behaviour. A later PR could remove
# one of these without a single model spec failing, so they are asserted directly
# against the database.
RSpec.describe "Core data model schema" do
  let(:connection) { ActiveRecord::Base.connection }

  it "defines every table plan §7 specifies" do
    expect(connection.tables).to include(
      "event_sources", "github_api_budget", "ingestion_runs", "push_events",
      "quarantined_events", "github_actors", "github_repositories"
    )
  end

  describe "github_api_budget" do
    # The ledger's columns are the ledger's contract: PR 4 reserves against these
    # counters, and a silently dropped or renamed one would break accounting.
    it "carries exactly the columns the ledger reserves against" do
      expect(connection.columns("github_api_budget").map(&:name)).to match_array(%w[
        id resource limit remaining reset_at global_blocked_until
        window_status window_initialized_at
        poll_allowance poll_used enrichment_allowance enrichment_used
        actor_share_used repository_share_used reserve
        observed_at lock_version created_at updated_at
      ])
    end

    it "constrains itself to a single row" do
      names = connection.check_constraints("github_api_budget").map(&:name)

      expect(names).to include("github_api_budget_singleton")
    end
  end

  describe "push_events" do
    it "requires every structured column" do
      nullable = connection.columns("push_events").reject(&:null).map(&:name)

      expect(nullable).to match_array(%w[
        id github_event_id github_push_id github_repository_id github_actor_id
        ref head_sha before_sha occurred_at raw_payload created_at updated_at
      ])
    end

    it "sizes both SHA columns for SHA-256 object names" do
      %w[head_sha before_sha].each do |name|
        column = connection.columns("push_events").find { |c| c.name == name }
        expect(column.limit).to eq(64)
      end
    end

    it "makes the GitHub event id unique" do
      index = connection.indexes("push_events").find { |i| i.columns == [ "github_event_id" ] }

      expect(index.unique).to be(true)
    end

    # Possible because the ingest transaction upserts stub entity rows first (§7).
    it "references the entity tables by their GitHub id, not the surrogate key" do
      keys = connection.foreign_keys("push_events")

      expect(keys.map { |k| [ k.to_table, k.options[:column], k.options[:primary_key] ] })
        .to contain_exactly(
          [ "github_actors", "github_actor_id", "github_id" ],
          [ "github_repositories", "github_repository_id", "github_id" ]
        )
    end

    it "carries no GIN index on the raw payload until a query demands one" do
      expect(connection.indexes("push_events").map(&:columns)).not_to include([ "raw_payload" ])
    end
  end

  describe "quarantined_events" do
    it "makes the payload fingerprint the only unique identity" do
      unique = connection.indexes("quarantined_events").select(&:unique).map(&:columns)

      expect(unique).to eq([ [ "payload_fingerprint" ] ])
    end
  end

  describe "the entity tables" do
    it "each carry the same enrichment state columns" do
      enrichment_columns = %w[
        enrichment_status enrichment_attempts next_retry_at last_error fetched_at
        first_seen_at last_seen_at latest_event_at skipped_at
      ]

      %w[github_actors github_repositories].each do |table|
        expect(connection.columns(table).map(&:name)).to include(*enrichment_columns)
      end
    end

    it "each carry a partial index over the reconciler's ordering columns" do
      %w[github_actors github_repositories].each do |table|
        index = connection.indexes(table)
                          .find { |i| i.name == "index_#{table}_on_enrichment_candidates" }

        expect(index).not_to be_nil, "expected a candidate index on #{table}"
        expect(index.where).to be_present
      end
    end

    it "stores enrichment status as text so the index predicate needs no cast" do
      %w[github_actors github_repositories].each do |table|
        column = connection.columns(table).find { |c| c.name == "enrichment_status" }
        expect(column.type).to eq(:text)
      end
    end
  end

  describe "event_sources" do
    # Plan §9 requires these to stay separate; a single collapsed timestamp would make
    # --force unable to identify which constraint it may bypass.
    it "keeps each scheduling component as its own column" do
      expect(connection.columns("event_sources").map(&:name)).to include(
        "cadence_due_at", "poll_floor_until", "retry_not_before_at", "next_poll_at"
      )
    end

    # Every other status vocabulary in this schema carries both an `enum … validate: true`
    # and a CHECK constraint. A NOT NULL column with no default and no constraint would
    # make this table the sole exception.
    it "constrains the poll status to its vocabulary" do
      names = connection.check_constraints("event_sources").map(&:name)

      expect(names).to include("event_sources_status_known")
    end

    # PR 8 adds the "which sources are due" query and should add the index that serves it
    # in the same change, where its plan is checkable. Asserting the absence keeps that a
    # visible decision rather than an oversight.
    it "carries no index yet, because the query that would use one does not exist" do
      expect(connection.indexes("event_sources")).to be_empty
    end
  end
end
