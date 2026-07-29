# The durability boundary: a GitHub event is accepted only once its push_events row
# commits (§8). Every structured column is NOT NULL — the tolerant parser requires
# repository_id, push_id, ref, head, and before, and routes anything missing them to
# quarantine rather than persisting a partial row (§7).
#
# The foreign keys reference github_id (a unique non-primary-key column) rather than
# the surrogate ids, which is why the entity tables are created first. They are
# satisfiable because the ingest transaction upserts stub entity rows before the
# event insert (§7).
#
# No CHECK constraints: §7's enumerated constraint list has none, and SHA shape is
# enforced in Ruby so a malformed value routes to quarantine instead of raising a
# StatementInvalid that would abort the whole batch.
class CreatePushEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :push_events do |t|
      # GitHub event IDs are large numerics delivered as strings.
      t.text :github_event_id, null: false
      t.bigint :github_push_id, null: false
      t.bigint :github_repository_id, null: false
      t.bigint :github_actor_id, null: false
      t.text :ref, null: false

      # Git object IDs are 40 hex chars under SHA-1 and 64 under SHA-256. Payload
      # fields `head` and `before`; exposed under those names in serializers.
      t.string :head_sha, limit: 64, null: false
      t.string :before_sha, limit: 64, null: false

      t.datetime :occurred_at, null: false

      # Semantic retention, not byte-exact — see docs/adr/0001-jsonb-semantic-retention.md.
      t.jsonb :raw_payload, null: false

      t.timestamps
    end

    # Inserts use ON CONFLICT (github_event_id) DO NOTHING RETURNING id; the presence
    # of a returned row is what gates entity activity updates (§7).
    add_index :push_events, :github_event_id, unique: true
    add_index :push_events, :github_push_id
    add_index :push_events, :github_repository_id
    add_index :push_events, :github_actor_id
    add_index :push_events, :occurred_at

    # No GIN index on raw_payload: §7 gates it on a demonstrated query, and there
    # is not one yet.

    add_foreign_key :push_events, :github_repositories,
                    column: :github_repository_id, primary_key: :github_id
    add_foreign_key :push_events, :github_actors,
                    column: :github_actor_id, primary_key: :github_id
  end
end
