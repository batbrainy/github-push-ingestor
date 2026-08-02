require "rails_helper"

# Guarantees that live in the schema rather than in behaviour. A later PR could remove
# one of these without a single model spec failing, so they are asserted directly
# against the database.
RSpec.describe "Core data model schema" do
  let(:connection) { ActiveRecord::Base.connection }

  it "defines every table plan §7 specifies" do
    expect(connection.tables).to include(
      "event_sources", "github_api_budget", "ingestion_runs", "push_events",
      "quarantined_events", "github_actors", "github_repositories",
      "github_search_budget", "enrichment_batches", "enrichment_observations"
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
        consecutive_secondary_limits
        observed_at lock_version created_at updated_at
      ])
    end

    it "constrains itself to a single row" do
      names = connection.check_constraints("github_api_budget").map(&:name)

      expect(names).to include("github_api_budget_singleton")
    end
  end

  describe "github_search_budget" do
    # Mirrors the core ledger's posture above: the Search ledger's columns are its
    # contract, and Github::SearchBudgetLedger reserves against exactly these counters.
    it "carries exactly the columns the search ledger reserves against" do
      expect(connection.columns("github_search_budget").map(&:name)).to match_array(%w[
        id resource limit remaining reset_at observed_at
        request_ceiling reserve used actor_used repository_used
        blocked_until last_request_at
        lock_version created_at updated_at
      ])
    end

    it "constrains itself to a single row" do
      names = connection.check_constraints("github_search_budget").map(&:name)

      expect(names).to include("github_search_budget_singleton")
    end

    it "refuses negative counters at the schema level" do
      names = connection.check_constraints("github_search_budget").map(&:name)

      expect(names).to include("github_search_budget_counters_valid")
    end
  end

  describe "enrichment_batches" do
    it "carries the request envelope, counters, and rate-limit evidence columns" do
      expect(connection.columns("enrichment_batches").map(&:name)).to include(
        "correlation_id", "request_kind", "entity_kind", "status",
        "requested_github_ids", "requested_identifiers", "request_url",
        "response_status", "response_body", "total_count", "incomplete_results",
        "requested_count", "returned_count", "valid_count", "missing_count", "invalid_count",
        "started_at", "completed_at",
        "rate_limit_resource", "rate_limit_limit", "rate_limit_remaining",
        "rate_limit_used", "rate_limit_reset_at", "last_error"
      )
    end

    it "makes the correlation id unique" do
      index = connection.indexes("enrichment_batches")
                        .find { |i| i.columns == [ "correlation_id" ] }

      expect(index.unique).to be(true)
    end

    # The /status batch-quality window filters on started_at alone; the composite index
    # cannot range-scan it because started_at is its last column.
    it "indexes both the per-kind history and the bare started_at window" do
      columns = connection.indexes("enrichment_batches").map(&:columns)

      expect(columns).to include(%w[request_kind entity_kind started_at])
      expect(columns).to include([ "started_at" ])
    end

    it "constrains kind, entity, status, and counter signs" do
      names = connection.check_constraints("enrichment_batches").map(&:name)

      expect(names).to include(
        "enrichment_batches_request_kind_check",
        "enrichment_batches_entity_kind_check",
        "enrichment_batches_status_check",
        "enrichment_batches_counters_nonnegative"
      )
    end
  end

  describe "enrichment_observations" do
    it "carries the append-only evidence columns" do
      expect(connection.columns("enrichment_observations").map(&:name)).to include(
        "entity_kind", "entity_github_id", "source", "observed_at",
        "raw_payload", "payload_fingerprint", "enrichment_batch_id", "push_event_id",
        "request_correlation_id", "requested_identifier", "validation_outcome"
      )
    end

    it "indexes the per-entity timeline and the fingerprint" do
      indexes = connection.indexes("enrichment_observations")

      timeline = indexes.find { |i| i.name == "index_enrichment_observations_on_entity_and_time" }
      expect(timeline.columns).to eq(%w[entity_kind entity_github_id observed_at])
      expect(indexes.map(&:columns)).to include([ "payload_fingerprint" ])
    end

    it "constrains entity kind and source to their vocabularies" do
      names = connection.check_constraints("enrichment_observations").map(&:name)

      expect(names).to include(
        "enrichment_observations_entity_kind_check",
        "enrichment_observations_source_check"
      )
    end

    it "references its batch and its push event with real foreign keys" do
      tables = connection.foreign_keys("enrichment_observations").map(&:to_table)

      expect(tables).to contain_exactly("enrichment_batches", "push_events")
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

  # The same posture for every raw_payload in the schema: retention is a durability
  # decision, indexing is a query decision, and no query demands one yet.
  describe "raw payload retention" do
    it "carries no GIN index on any raw_payload column" do
      %w[push_events quarantined_events enrichment_observations
         github_actors github_repositories].each do |table|
        expect(connection.indexes(table).map(&:columns)).not_to include([ "raw_payload" ]),
                                                                "expected no raw_payload index on #{table}"
      end
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
        first_seen_at last_seen_at latest_event_at
      ]

      %w[github_actors github_repositories].each do |table|
        column_names = connection.columns(table).map(&:name)

        expect(column_names).to include(*enrichment_columns)
        expect(column_names).not_to include("skipped_at")
      end
    end

    # Appendix G's staged pipeline: the stage machine's resting position, the instant
    # columns for the three non-resting facts, and the lease that makes a claim durable.
    it "each carry the same staged pipeline columns" do
      staged_columns = %w[
        enrichment_stage detail_attempts event_native_at derived_at batch_pending_at
        batch_applied_at detail_pending_at retry_scheduled_at contract_completed_at
        terminal_at latest_observation_id latest_observation_source latest_observed_at
        lease_token leased_until current_enrichment_batch_id
      ]

      %w[github_actors github_repositories].each do |table|
        expect(connection.columns(table).map(&:name)).to include(*staged_columns)
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

    # BatchClaim's FIFO is `ORDER BY created_at, id` under a stage predicate; the index
    # leads with the stage so the order it yields is the order the claim reads.
    it "each index the staged FIFO in claim order" do
      %w[github_actors github_repositories].each do |table|
        index = connection.indexes(table).find { |i| i.name == "index_#{table}_on_stage_fifo" }

        expect(index).not_to be_nil, "expected index_#{table}_on_stage_fifo"
        expect(index.columns).to eq(%w[enrichment_stage created_at id])
      end
    end

    # The lease-expiry predicate (`leased_until IS NULL OR leased_until <= now`) is on
    # every claim scope, so expiry re-admission never scans the table.
    it "each index leased_until for lease-expiry reclaims" do
      %w[github_actors github_repositories].each do |table|
        expect(connection.indexes(table).map(&:columns)).to include([ "leased_until" ]),
                                                            "expected a leased_until index on #{table}"
      end
    end

    it "each constrain the stage to the seven resting stages" do
      %w[github_actors github_repositories].each do |table|
        names = connection.check_constraints(table).map(&:name)

        expect(names).to include("#{table}_enrichment_stage_check")
        expect(names).to include("#{table}_detail_attempts_nonnegative")
      end
    end

    it "stores enrichment status and stage as text so the index predicates need no cast" do
      %w[github_actors github_repositories].each do |table|
        %w[enrichment_status enrichment_stage].each do |name|
          column = connection.columns(table).find { |c| c.name == name }
          expect(column.type).to eq(:text)
        end
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

    # PR 8's recurring tick is the query that needed one, and it arrived in the same change.
    # The predicate here and EventSource.poll_due's WHERE are the same sentence written
    # twice, so this example is what keeps them from drifting apart.
    it "indexes the recurring tick's due-source query" do
      index = connection.indexes("event_sources").find { |i| i.name == "index_event_sources_on_poll_due" }

      expect(index).not_to be_nil, "expected index_event_sources_on_poll_due"
      expect(index.columns).to eq(%w[source_type next_poll_at])
      expect(index.where).to include("enabled").and include("idle")
    end
  end

  # Solid Queue lives in its own database (§2A), and the outbox-style recovery argument
  # depends on that being true rather than intended: if these tables were here, an enqueue
  # could join the business transaction and "the committed entity state is the durable record
  # of pending work" would stop being the reason the reconciler exists.
  describe "the queue database boundary" do
    it "keeps Solid Queue's tables out of the primary database" do
      expect(connection.tables.grep(/solid_queue/)).to be_empty
    end
  end
end
