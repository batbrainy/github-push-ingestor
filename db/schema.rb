# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_29_210007) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "event_sources", force: :cascade do |t|
    t.datetime "cadence_due_at"
    t.jsonb "configuration", default: {}, null: false
    t.integer "consecutive_failures", default: 0, null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.text "etag"
    t.text "last_error"
    t.datetime "last_polled_at"
    t.datetime "last_success_at"
    t.datetime "next_poll_at"
    t.datetime "poll_floor_until"
    t.datetime "retry_not_before_at"
    t.text "source_type", null: false
    t.text "status", null: false
    t.datetime "updated_at", null: false
    t.check_constraint "consecutive_failures >= 0", name: "event_sources_consecutive_failures_nonnegative"
  end

  create_table "github_actors", force: :cascade do |t|
    t.text "api_url"
    t.text "avatar_url"
    t.datetime "created_at", null: false
    t.text "display_login"
    t.integer "enrichment_attempts", default: 0, null: false
    t.text "enrichment_status", default: "pending", null: false
    t.datetime "fetched_at"
    t.datetime "first_seen_at"
    t.bigint "github_id", null: false
    t.text "last_error"
    t.datetime "last_seen_at"
    t.datetime "latest_event_at"
    t.text "login", null: false
    t.text "name"
    t.datetime "next_retry_at"
    t.jsonb "raw_payload"
    t.datetime "skipped_at"
    t.datetime "updated_at", null: false
    t.index ["github_id"], name: "index_github_actors_on_github_id", unique: true
    t.index ["next_retry_at", "last_seen_at"], name: "index_github_actors_on_enrichment_candidates", where: "(enrichment_status = ANY (ARRAY['pending'::text, 'retryable_failure'::text]))"
    t.check_constraint "enrichment_attempts >= 0", name: "github_actors_enrichment_attempts_nonnegative"
    t.check_constraint "enrichment_status = ANY (ARRAY['pending'::text, 'complete'::text, 'retryable_failure'::text, 'permanent_failure'::text, 'skipped_budget'::text])", name: "github_actors_enrichment_status_check"
  end

  create_table "github_api_budget", id: :integer, default: 1, force: :cascade do |t|
    t.integer "actor_share_used", default: 0, null: false
    t.datetime "created_at", null: false
    t.integer "enrichment_allowance", default: 0, null: false
    t.integer "enrichment_used", default: 0, null: false
    t.datetime "global_blocked_until"
    t.integer "limit"
    t.integer "lock_version", default: 0, null: false
    t.datetime "observed_at"
    t.integer "poll_allowance", default: 0, null: false
    t.integer "poll_used", default: 0, null: false
    t.integer "remaining"
    t.integer "repository_share_used", default: 0, null: false
    t.integer "reserve", default: 0, null: false
    t.datetime "reset_at"
    t.text "resource", default: "core", null: false
    t.datetime "updated_at", null: false
    t.datetime "window_initialized_at"
    t.text "window_status", default: "uninitialized", null: false
    t.check_constraint "id = 1", name: "github_api_budget_singleton"
    t.check_constraint "poll_allowance >= 0 AND poll_used >= 0 AND enrichment_allowance >= 0 AND enrichment_used >= 0 AND actor_share_used >= 0 AND repository_share_used >= 0 AND reserve >= 0 AND (\"limit\" IS NULL OR \"limit\" >= 0) AND (remaining IS NULL OR remaining >= 0)", name: "github_api_budget_counters_nonnegative"
    t.check_constraint "window_status = ANY (ARRAY['uninitialized'::text, 'active'::text, 'globally_blocked'::text])", name: "github_api_budget_window_status_check"
  end

  create_table "github_repositories", force: :cascade do |t|
    t.text "api_url"
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "enrichment_attempts", default: 0, null: false
    t.text "enrichment_status", default: "pending", null: false
    t.datetime "fetched_at"
    t.datetime "first_seen_at"
    t.text "full_name", null: false
    t.bigint "github_id", null: false
    t.text "language"
    t.text "last_error"
    t.datetime "last_seen_at"
    t.datetime "latest_event_at"
    t.text "name"
    t.datetime "next_retry_at"
    t.bigint "owner_github_id"
    t.jsonb "raw_payload"
    t.datetime "skipped_at"
    t.datetime "updated_at", null: false
    t.index ["github_id"], name: "index_github_repositories_on_github_id", unique: true
    t.index ["next_retry_at", "last_seen_at"], name: "index_github_repositories_on_enrichment_candidates", where: "(enrichment_status = ANY (ARRAY['pending'::text, 'retryable_failure'::text]))"
    t.check_constraint "enrichment_attempts >= 0", name: "github_repositories_enrichment_attempts_nonnegative"
    t.check_constraint "enrichment_status = ANY (ARRAY['pending'::text, 'complete'::text, 'retryable_failure'::text, 'permanent_failure'::text, 'skipped_budget'::text])", name: "github_repositories_enrichment_status_check"
  end

  create_table "ingestion_runs", force: :cascade do |t|
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.integer "duplicates_skipped", default: 0, null: false
    t.bigint "event_source_id", null: false
    t.integer "events_created", default: 0, null: false
    t.integer "events_failed", default: 0, null: false
    t.integer "events_quarantined", default: 0, null: false
    t.integer "events_received", default: 0, null: false
    t.text "last_error"
    t.integer "pages_fetched", default: 0, null: false
    t.integer "push_events_seen", default: 0, null: false
    t.uuid "run_id", default: -> { "gen_random_uuid()" }, null: false
    t.datetime "started_at", null: false
    t.text "status", null: false
    t.datetime "updated_at", null: false
    t.index ["event_source_id"], name: "index_ingestion_runs_on_event_source_id"
    t.index ["run_id"], name: "index_ingestion_runs_on_run_id", unique: true
    t.check_constraint "pages_fetched >= 0 AND events_received >= 0 AND push_events_seen >= 0 AND events_created >= 0 AND duplicates_skipped >= 0 AND events_quarantined >= 0 AND events_failed >= 0", name: "ingestion_runs_counters_nonnegative"
  end

  create_table "push_events", force: :cascade do |t|
    t.string "before_sha", limit: 64, null: false
    t.datetime "created_at", null: false
    t.bigint "github_actor_id", null: false
    t.text "github_event_id", null: false
    t.bigint "github_push_id", null: false
    t.bigint "github_repository_id", null: false
    t.string "head_sha", limit: 64, null: false
    t.datetime "occurred_at", null: false
    t.jsonb "raw_payload", null: false
    t.text "ref", null: false
    t.datetime "updated_at", null: false
    t.index ["github_actor_id"], name: "index_push_events_on_github_actor_id"
    t.index ["github_event_id"], name: "index_push_events_on_github_event_id", unique: true
    t.index ["github_push_id"], name: "index_push_events_on_github_push_id"
    t.index ["github_repository_id"], name: "index_push_events_on_github_repository_id"
    t.index ["occurred_at"], name: "index_push_events_on_occurred_at"
  end

  create_table "quarantined_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error_code"
    t.text "error_message"
    t.text "event_type"
    t.datetime "first_received_at", null: false
    t.text "github_event_id"
    t.datetime "last_received_at", null: false
    t.integer "occurrence_count", default: 1, null: false
    t.text "payload_fingerprint", null: false
    t.jsonb "raw_payload", null: false
    t.datetime "updated_at", null: false
    t.index ["github_event_id"], name: "index_quarantined_events_on_github_event_id"
    t.index ["payload_fingerprint"], name: "index_quarantined_events_on_payload_fingerprint", unique: true
    t.check_constraint "occurrence_count >= 1", name: "quarantined_events_occurrence_count_positive"
  end

  add_foreign_key "ingestion_runs", "event_sources"
  add_foreign_key "push_events", "github_actors", primary_key: "github_id"
  add_foreign_key "push_events", "github_repositories", primary_key: "github_id"
end
