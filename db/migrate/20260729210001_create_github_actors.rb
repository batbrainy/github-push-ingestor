# GitHub actors are shared entities: many push events reference one actor, so
# enrichment state lives here rather than per event (IMPLEMENTATION_PLAN.md §7).
class CreateGithubActors < ActiveRecord::Migration[8.1]
  def change
    create_table :github_actors do |t|
      t.bigint :github_id, null: false
      t.text :login, null: false
      t.text :display_login
      t.text :api_url
      t.text :avatar_url

      # Populated by enrichment; NULL on envelope-derived stubs.
      t.text :name
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

      t.check_constraint <<~SQL.squish, name: "github_actors_enrichment_status_check"
        enrichment_status IN ('pending', 'complete', 'retryable_failure',
                              'permanent_failure', 'skipped_budget')
      SQL
      t.check_constraint "enrichment_attempts >= 0",
                         name: "github_actors_enrichment_attempts_nonnegative"
    end

    add_index :github_actors, :github_id, unique: true

    # Predicate matches the enrichment reconciler's exact WHERE clause (§7).
    add_index :github_actors, [ :next_retry_at, :last_seen_at ],
              where: "enrichment_status IN ('pending', 'retryable_failure')",
              name: "index_github_actors_on_enrichment_candidates"
  end
end
