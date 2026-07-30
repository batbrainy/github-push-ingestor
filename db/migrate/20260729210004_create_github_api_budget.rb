# Single-row global ledger through which every outbound live request from any process
# reserves capacity before execution (§7, §10). The unauthenticated 60 req/hour limit
# is keyed to the outbound IP, not to a source row, so this ledger is global.
#
# Deliberately absent: poll_class_blocked_until / enrichment_class_blocked_until.
# Class blocking is derived from the counters and never stored (§10) — only truly
# global blocks land in global_blocked_until.
class CreateGithubApiBudget < ActiveRecord::Migration[8.1]
  def change
    create_table :github_api_budget, id: false do |t|
      t.integer :id, primary_key: true, default: 1, null: false
      t.text :resource, null: false, default: "core"

      # Authoritative header values; NULL until the first poll of a window
      # bootstraps the ledger from a real response (§7).
      t.integer :limit
      t.integer :remaining
      t.datetime :reset_at               # window boundary — informational only

      t.datetime :global_blocked_until
      t.text :window_status, null: false, default: "uninitialized"
      t.datetime :window_initialized_at

      t.integer :poll_allowance, null: false, default: 0
      t.integer :poll_used, null: false, default: 0
      t.integer :enrichment_allowance, null: false, default: 0
      t.integer :enrichment_used, null: false, default: 0
      t.integer :actor_share_used, null: false, default: 0
      t.integer :repository_share_used, null: false, default: 0
      t.integer :reserve, null: false, default: 0

      t.datetime :observed_at
      t.integer :lock_version, null: false, default: 0

      t.timestamps

      t.check_constraint "id = 1", name: "github_api_budget_singleton"

      t.check_constraint <<~SQL.squish, name: "github_api_budget_window_status_check"
        window_status IN ('uninitialized', 'active', 'globally_blocked')
      SQL

      # Non-negativity only. Reservation arithmetic (used <= allowance, reserve
      # headroom) is PR 4's to define; encoding it here would turn a benign
      # transient into a batch-aborting StatementInvalid.
      t.check_constraint <<~SQL.squish, name: "github_api_budget_counters_nonnegative"
        poll_allowance >= 0 AND poll_used >= 0
        AND enrichment_allowance >= 0 AND enrichment_used >= 0
        AND actor_share_used >= 0 AND repository_share_used >= 0
        AND reserve >= 0
        AND ("limit" IS NULL OR "limit" >= 0)
        AND (remaining IS NULL OR remaining >= 0)
      SQL
    end
  end
end
