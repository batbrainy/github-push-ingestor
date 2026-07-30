# One row per polling cycle. run_id is the stable correlation identifier shared by the
# poller, worker, logs, and status output (§7, §11).
#
# status has no default and no CHECK here on purpose — PR 5 owns run summaries and the
# run state vocabulary.
class CreateIngestionRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :ingestion_runs do |t|
      # gen_random_uuid() is in core PostgreSQL from 13 onward, so no pgcrypto.
      t.uuid :run_id, null: false, default: -> { "gen_random_uuid()" }
      t.references :event_source, null: false, foreign_key: true

      t.datetime :started_at, null: false
      t.datetime :completed_at
      t.text :status, null: false

      t.integer :pages_fetched, null: false, default: 0
      t.integer :events_received, null: false, default: 0
      t.integer :push_events_seen, null: false, default: 0
      t.integer :events_created, null: false, default: 0
      t.integer :duplicates_skipped, null: false, default: 0
      t.integer :events_quarantined, null: false, default: 0
      t.integer :events_failed, null: false, default: 0

      t.text :last_error

      t.timestamps

      t.check_constraint <<~SQL.squish, name: "ingestion_runs_counters_nonnegative"
        pages_fetched >= 0 AND events_received >= 0 AND push_events_seen >= 0
        AND events_created >= 0 AND duplicates_skipped >= 0
        AND events_quarantined >= 0 AND events_failed >= 0
      SQL
    end

    add_index :ingestion_runs, :run_id, unique: true
  end
end
