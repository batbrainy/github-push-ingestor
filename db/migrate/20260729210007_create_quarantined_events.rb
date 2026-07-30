# Durable home for events that fail validation — "malformed" is a defined predicate,
# not an exception path ending in a log line (§7).
#
# A malformed event may be malformed precisely because it lacks an event ID, so the
# fingerprint is the ONLY uniqueness constraint. The same github_event_id arriving
# with a different malformed payload is a different quarantine row, not a conflict —
# hence github_event_id is indexed but not unique.
#
# raw_payload is deliberately nullable. §7's taxonomy quarantines an event with an
# invalid envelope, and a valid JSON events array can legitimately contain `null`, `{}`,
# or `[]` as an element — all parsed values with no usable envelope. Rejecting them here
# would raise a NotNullViolation inside the ingest transaction and destroy the very
# malformed event quarantine exists to preserve. Only a wholly unparseable response body
# is an ingestion failure rather than a quarantine row.
#
# payload_fingerprint stays NOT NULL regardless: the canonical fingerprint of `null` is
# as well defined as any other, so identity survives a null payload.
class CreateQuarantinedEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :quarantined_events do |t|
      t.text :github_event_id
      t.text :payload_fingerprint, null: false
      t.text :event_type
      t.jsonb :raw_payload

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
