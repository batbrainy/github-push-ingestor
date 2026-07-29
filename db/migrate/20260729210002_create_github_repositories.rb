# Same shared-entity and enrichment-state design as github_actors
# (IMPLEMENTATION_PLAN.md §7 — "the identical enrichment state machine").
class CreateGithubRepositories < ActiveRecord::Migration[8.1]
  def change
    create_table :github_repositories do |t|
      t.bigint :github_id, null: false

      # full_name is the envelope's qualified owner/repository form; name is its
      # final segment and is deliberately not equated with it (§7).
      t.text :full_name, null: false
      t.text :name
      t.text :api_url

      # Populated by enrichment; NULL on envelope-derived stubs.
      t.text :description
      t.text :language
      t.bigint :owner_github_id
      t.jsonb :raw_payload

      t.text :enrichment_status, null: false, default: "pending"
      t.integer :enrichment_attempts, null: false, default: 0
      t.datetime :next_retry_at
      t.text :last_error
      t.datetime :fetched_at

      # Activity fields advance only for distinct persisted push events (§7).
      t.datetime :first_seen_at
      t.datetime :last_seen_at
      t.datetime :latest_event_at
      t.datetime :skipped_at

      t.timestamps

      t.check_constraint <<~SQL.squish, name: "github_repositories_enrichment_status_check"
        enrichment_status IN ('pending', 'complete', 'retryable_failure',
                              'permanent_failure', 'skipped_budget')
      SQL
      t.check_constraint "enrichment_attempts >= 0",
                         name: "github_repositories_enrichment_attempts_nonnegative"
    end

    add_index :github_repositories, :github_id, unique: true

    add_index :github_repositories, [ :next_retry_at, :last_seen_at ],
              where: "enrichment_status IN ('pending', 'retryable_failure')",
              name: "index_github_repositories_on_enrichment_candidates"
  end
end
