# Scheduling constraints are persisted as separate components, never collapsed into
# one timestamp: --force must be able to bypass exactly one of them, and a routine
# X-RateLimit-Reset must not defer every poll to the top of the hour (§7, §9).
#
# status has no default and no CHECK constraint here on purpose. No vocabulary for it
# is defined anywhere in the plan, and PR 6 owns the poll state machine — inventing a
# value set now would pre-empt that decision.
class CreateEventSources < ActiveRecord::Migration[8.1]
  def change
    create_table :event_sources do |t|
      t.text :source_type, null: false
      t.jsonb :configuration, null: false, default: {}
      t.boolean :enabled, null: false, default: true
      t.text :status, null: false

      # Applies only to the canonical first-page request and its stable query
      # parameters; Link-followed pages never reuse it (§9).
      t.text :etag

      t.datetime :cadence_due_at        # configured cadence
      t.datetime :poll_floor_until      # X-Poll-Interval — server floor
      t.datetime :retry_not_before_at   # source-scoped Retry-After / backoff
      t.datetime :next_poll_at          # optional cached effective value

      t.datetime :last_polled_at
      t.datetime :last_success_at
      t.integer :consecutive_failures, null: false, default: 0
      t.text :last_error

      t.timestamps

      t.check_constraint "consecutive_failures >= 0",
                         name: "event_sources_consecutive_failures_nonnegative"
    end
  end
end
