class PushEvent < ApplicationRecord
  # Git object IDs are 40 hex characters under SHA-1 and 64 under SHA-256. Hard-coding
  # 40 would conflict with the tolerant-parser goal (§7).
  SHA_FORMAT = /\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z/

  # optional: true deliberately. Referential integrity is guaranteed by the database
  # foreign keys on github_id; a required belongs_to would additionally issue a SELECT
  # per validation, making insert_if_new's guard depend on a database round trip for a
  # rule the database already enforces.
  belongs_to :github_actor,
             primary_key: :github_id,
             foreign_key: :github_actor_id,
             inverse_of: :push_events,
             optional: true

  belongs_to :github_repository,
             primary_key: :github_id,
             foreign_key: :github_repository_id,
             inverse_of: :push_events,
             optional: true

  validates :github_event_id, :github_push_id, :github_repository_id,
            :github_actor_id, :ref, :occurred_at, :raw_payload,
            presence: true

  validates :head_sha, :before_sha,
            format: { with: SHA_FORMAT,
                      message: "must be 40 or 64 hexadecimal characters" }

  # The duplicate-event insert gate the accepted-row guarantee rests on (§7, §8). Returns
  # the new row's id, or nil when the event was already persisted — and the caller uses
  # exactly that distinction to decide whether entity activity may be updated, so a
  # re-polled window cannot resurrect skipped entities.
  #
  # The explicit validate! is load-bearing: insert bypasses Active Record
  # validations, so without it SHA_FORMAT would never run on the real write path.
  # PR 5's parser is still the routing point that sends malformed events to
  # quarantine; reaching this raise means the parser let something through.
  #
  # No uniqueness *validation* is declared — that would issue a racy SELECT. The
  # unique index on github_event_id is the arbiter.
  def self.insert_if_new(attributes)
    new(attributes).validate!

    insert(
      attributes,
      unique_by: :github_event_id,
      returning: %w[id],
      record_timestamps: true
    ).rows.dig(0, 0)
  end
end
