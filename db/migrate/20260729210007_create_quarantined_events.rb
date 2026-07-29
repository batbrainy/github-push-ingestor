# Durable home for events that fail validation — "malformed" is a defined predicate,
# not an exception path ending in a log line (§7).
#
# A malformed event may be malformed precisely because it lacks an event ID, so the
# fingerprint is the ONLY uniqueness constraint. The same github_event_id arriving
# with a different malformed payload is a different quarantine row, not a conflict —
# hence github_event_id is indexed but not unique.
#
# raw_payload is NOT NULL, a deliberate tightening past §7's bare `jsonb`: an entire
# response body that is invalid JSON is an ingestion failure rather than a quarantine
# row (§7 taxonomy), so every quarantined event has a parsed payload — and the NOT
# NULL fingerprint is derived from it.
class CreateQuarantinedEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :quarantined_events do |t|
      t.text :github_event_id
      t.text :payload_fingerprint, null: false
      t.text :event_type
      t.jsonb :raw_payload, null: false

      t.text :error_code
      t.text :error_message

      t.datetime :first_received_at, null: false
      t.datetime :last_received_at, null: false
      t.integer :occurrence_count, null: false, default: 1

      t.timestamps

      t.check_constraint "occurrence_count >= 1",
                         name: "quarantined_events_occurrence_count_positive"

      # No last_received_at >= first_received_at constraint: the upsert makes the
      # write monotonic instead, so a constraint would only convert a benign
      # out-of-order replay into an aborted transaction.
    end

    add_index :quarantined_events, :payload_fingerprint, unique: true
    add_index :quarantined_events, :github_event_id
  end
end
