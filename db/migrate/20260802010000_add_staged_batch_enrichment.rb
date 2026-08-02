class AddStagedBatchEnrichment < ActiveRecord::Migration[8.1]
  ENTITY_TABLES = %i[github_actors github_repositories].freeze

  def up
    create_table :enrichment_batches do |t|
      t.uuid :correlation_id, null: false, default: -> { "gen_random_uuid()" }
      t.text :request_kind, null: false
      t.text :entity_kind, null: false
      t.text :status, null: false, default: "in_flight"
      t.jsonb :requested_github_ids, null: false, default: []
      t.jsonb :requested_identifiers, null: false, default: []
      t.text :request_url
      t.integer :response_status
      t.text :response_body
      t.integer :total_count
      t.boolean :incomplete_results
      t.integer :requested_count, null: false, default: 0
      t.integer :returned_count, null: false, default: 0
      t.integer :valid_count, null: false, default: 0
      t.integer :missing_count, null: false, default: 0
      t.integer :invalid_count, null: false, default: 0
      t.datetime :started_at, null: false
      t.datetime :completed_at
      t.text :rate_limit_resource
      t.integer :rate_limit_limit
      t.integer :rate_limit_remaining
      t.integer :rate_limit_used
      t.datetime :rate_limit_reset_at
      t.text :last_error
      t.timestamps
    end
    add_index :enrichment_batches, :correlation_id, unique: true
    add_index :enrichment_batches, %i[request_kind entity_kind started_at]
    # The /status batch-quality window filters on started_at alone; the composite
    # index above cannot range-scan it because started_at is its last column.
    add_index :enrichment_batches, :started_at
    add_check_constraint :enrichment_batches,
                         "request_kind IN ('search', 'detail')",
                         name: "enrichment_batches_request_kind_check"
    add_check_constraint :enrichment_batches,
                         "entity_kind IN ('actor', 'repository')",
                         name: "enrichment_batches_entity_kind_check"
    add_check_constraint :enrichment_batches,
                         "status IN ('in_flight', 'succeeded', 'failed', 'deferred', 'stale_lease')",
                         name: "enrichment_batches_status_check"
    add_check_constraint :enrichment_batches,
                         "requested_count >= 0 AND returned_count >= 0 AND valid_count >= 0 " \
                         "AND missing_count >= 0 AND invalid_count >= 0",
                         name: "enrichment_batches_counters_nonnegative"

    create_table :enrichment_observations do |t|
      t.text :entity_kind, null: false
      t.bigint :entity_github_id
      t.text :source, null: false
      t.datetime :observed_at, null: false
      t.jsonb :raw_payload, null: false
      t.text :payload_fingerprint, null: false
      t.references :enrichment_batch, foreign_key: true
      t.references :push_event, foreign_key: true
      t.uuid :request_correlation_id
      t.text :requested_identifier
      t.text :validation_outcome, null: false
      t.timestamps
    end
    add_index :enrichment_observations,
              %i[entity_kind entity_github_id observed_at],
              name: "index_enrichment_observations_on_entity_and_time"
    add_index :enrichment_observations, :payload_fingerprint
    add_check_constraint :enrichment_observations,
                         "entity_kind IN ('actor', 'repository')",
                         name: "enrichment_observations_entity_kind_check"
    add_check_constraint :enrichment_observations,
                         "source IN ('event', 'search', 'detail')",
                         name: "enrichment_observations_source_check"

    create_table :github_search_budget, id: :integer, default: 1 do |t|
      t.text :resource, null: false, default: "search"
      t.integer :limit
      t.integer :remaining
      t.datetime :reset_at
      t.datetime :observed_at
      t.integer :request_ceiling, null: false, default: 10
      t.integer :reserve, null: false, default: 2
      t.integer :used, null: false, default: 0
      t.integer :actor_used, null: false, default: 0
      t.integer :repository_used, null: false, default: 0
      t.datetime :blocked_until
      t.datetime :last_request_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_check_constraint :github_search_budget, "id = 1",
                         name: "github_search_budget_singleton"
    add_check_constraint :github_search_budget,
                         "request_ceiling > 0 AND reserve >= 0 AND used >= 0 " \
                         "AND actor_used >= 0 AND repository_used >= 0 " \
                         "AND (\"limit\" IS NULL OR \"limit\" >= 0) " \
                         "AND (remaining IS NULL OR remaining >= 0)",
                         name: "github_search_budget_counters_valid"

    ENTITY_TABLES.each { |table| add_staged_columns(table) }

    add_column :github_actors, :account_type, :text

    add_column :github_repositories, :owner_login, :text
    add_column :github_repositories, :fork, :boolean
    add_column :github_repositories, :archived, :boolean
    add_column :github_repositories, :default_branch, :text
    add_column :github_repositories, :github_created_at, :datetime

    # Legacy rows joined the staged pipeline where their business outcome placed
    # them. A pre-staged `complete` row maps to contract_complete even though the
    # staged contract columns are NULL: its completion under the previous contract
    # is a fact, and the TTL refresh path re-evaluates it against the staged
    # contract within one refresh cycle.
    ENTITY_TABLES.each do |table|
      execute <<~SQL.squish
        UPDATE #{table}
           SET enrichment_stage = CASE enrichment_status
                 WHEN 'complete' THEN 'contract_complete'
                 WHEN 'permanent_failure' THEN 'terminal'
                 WHEN 'retryable_failure' THEN 'retry_scheduled'
                 ELSE 'batch_pending'
               END,
               event_native_at = COALESCE(first_seen_at, created_at),
               derived_at = COALESCE(first_seen_at, created_at),
               batch_pending_at = CASE WHEN enrichment_status IN ('pending', 'retryable_failure')
                                       THEN COALESCE(first_seen_at, created_at) END,
               retry_scheduled_at = CASE WHEN enrichment_status = 'retryable_failure'
                                         THEN updated_at END,
               contract_completed_at = CASE WHEN enrichment_status = 'complete'
                                            THEN fetched_at END,
               terminal_at = CASE WHEN enrichment_status = 'permanent_failure'
                                  THEN updated_at END
      SQL

      # Only resting stages are representable. Event-native persistence, local
      # derivation, and batch application are instants recorded by event_native_at,
      # derived_at, and batch_applied_at — no row ever rests in them, so they are
      # deliberately not enum values a metric or spec would have to enumerate.
      add_check_constraint table,
                           "enrichment_stage IN ('batch_pending', 'batch_in_flight', " \
                           "'detail_pending', 'detail_in_flight', 'retry_scheduled', " \
                           "'contract_complete', 'terminal')",
                           name: "#{table}_enrichment_stage_check"
    end
  end

  def down
    remove_column :github_repositories, :github_created_at
    remove_column :github_repositories, :default_branch
    remove_column :github_repositories, :archived
    remove_column :github_repositories, :fork
    remove_column :github_repositories, :owner_login
    remove_column :github_actors, :account_type

    ENTITY_TABLES.each { |table| remove_staged_columns(table) }

    drop_table :github_search_budget
    drop_table :enrichment_observations
    drop_table :enrichment_batches
  end

  private

  def add_staged_columns(table)
    add_column table, :enrichment_stage, :text, null: false, default: "batch_pending"
    add_column table, :detail_attempts, :integer, null: false, default: 0
    add_column table, :event_native_at, :datetime
    add_column table, :derived_at, :datetime
    add_column table, :batch_pending_at, :datetime
    add_column table, :batch_applied_at, :datetime
    add_column table, :detail_pending_at, :datetime
    add_column table, :retry_scheduled_at, :datetime
    add_column table, :contract_completed_at, :datetime
    add_column table, :terminal_at, :datetime
    add_reference table, :latest_observation, foreign_key: { to_table: :enrichment_observations }
    add_column table, :latest_observation_source, :text
    add_column table, :latest_observed_at, :datetime
    add_column table, :lease_token, :uuid
    add_column table, :leased_until, :datetime
    add_reference table, :current_enrichment_batch, foreign_key: { to_table: :enrichment_batches }
    add_index table, %i[enrichment_stage created_at id], name: "index_#{table}_on_stage_fifo"
    add_index table, :leased_until
    add_check_constraint table, "detail_attempts >= 0", name: "#{table}_detail_attempts_nonnegative"
  end

  def remove_staged_columns(table)
    remove_check_constraint table, name: "#{table}_enrichment_stage_check"
    remove_check_constraint table, name: "#{table}_detail_attempts_nonnegative"
    remove_index table, :leased_until
    remove_index table, name: "index_#{table}_on_stage_fifo"
    remove_reference table, :current_enrichment_batch, foreign_key: { to_table: :enrichment_batches }
    remove_column table, :leased_until
    remove_column table, :lease_token
    remove_column table, :latest_observed_at
    remove_column table, :latest_observation_source
    remove_reference table, :latest_observation, foreign_key: { to_table: :enrichment_observations }
    remove_column table, :terminal_at
    remove_column table, :contract_completed_at
    remove_column table, :retry_scheduled_at
    remove_column table, :detail_pending_at
    remove_column table, :batch_applied_at
    remove_column table, :batch_pending_at
    remove_column table, :derived_at
    remove_column table, :event_native_at
    remove_column table, :enrichment_stage
    remove_column table, :detail_attempts
  end
end
