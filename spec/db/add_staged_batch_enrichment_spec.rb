require "rails_helper"
require Rails.root.join("db/migrate/20260802010000_add_staged_batch_enrichment").to_s

# The staged-batch migration is the one that decides what happens to every entity row
# that predates Appendix G: each legacy business outcome must land on the one staged
# resting stage that means the same thing, or the durable FIFO would silently forget
# work (a pending row without batch_pending_at is invisible to BatchClaim's order).
#
# Choreography note, shared with the removal migration's spec (20260802000000): every
# down/up here goes through ActiveRecord::MigrationContext rather than a bare
# Migration#migrate. The context replays the migrations *in version order* and keeps
# schema_migrations truthful, and the around hook's ensure runs `migrate` back to the
# top whatever the example did — so a failure at any point still leaves the suite's
# schema fully migrated, and no later randomly-ordered spec inherits a half-reverted
# database. While the schema sits below this migration the entity models are unusable
# (their enrichment_stage enum has no backing column), so every read and write against
# the reverted schema goes through raw SQL.
RSpec.describe AddStagedBatchEnrichment, type: :migration do
  self.use_transactional_tests = false

  STAGED_ENTITY_COLUMNS = %w[
    enrichment_stage detail_attempts event_native_at derived_at batch_pending_at
    batch_applied_at detail_pending_at retry_scheduled_at contract_completed_at
    terminal_at latest_observation_id latest_observation_source latest_observed_at
    lease_token leased_until current_enrichment_batch_id
  ].freeze

  let(:connection) { ActiveRecord::Base.connection }

  # The version below this migration: `down(parent_version)` reverts exactly this
  # migration and nothing older.
  let(:parent_version) { 20260802000000 }

  let(:staged_actor_ids) { [ 99_300_001, 99_300_002, 99_300_003, 99_300_004 ] }
  let(:staged_repository_ids) { [ 99_400_001, 99_400_002, 99_400_003, 99_400_004 ] }

  # One instant per role, so every backfill assertion names its source column.
  let(:legacy_created_at) { Time.utc(2026, 7, 30, 9, 0, 0) }
  let(:legacy_seen_at) { Time.utc(2026, 7, 30, 10, 0, 0) }
  let(:legacy_updated_at) { Time.utc(2026, 7, 31, 11, 0, 0) }
  let(:legacy_fetched_at) { Time.utc(2026, 7, 31, 12, 0, 0) }

  around do |example|
    previous_verbose = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false

    begin
      example.run
    ensure
      # Whatever the example (or its failure) left behind, the suite continues on a
      # fully migrated schema.
      migration_context.migrate
      reset_schema_caches!
      GithubActor.where(github_id: staged_actor_ids).delete_all
      GithubRepository.where(github_id: staged_repository_ids).delete_all
      ActiveRecord::Migration.verbose = previous_verbose
    end
  end

  describe "the legacy-row backfill" do
    it "maps every pre-staged business outcome onto its one staged resting stage" do
      migration_context.down(parent_version)
      reset_schema_caches!
      insert_legacy_rows!

      migration_context.migrate
      reset_schema_caches!

      [ GithubActor, GithubRepository ].zip([ staged_actor_ids, staged_repository_ids ]).each do |model, ids|
        pending_row, complete, retryable, permanent = ids.map { model.find_by!(github_id: _1) }

        # pending → batch_pending: never-enriched work re-enters the FIFO, and the
        # first_seen_at fallback proves COALESCE reaches created_at when the row
        # predates activity tracking.
        expect(pending_row).to have_attributes(
          enrichment_status: "pending", enrichment_stage: "batch_pending",
          event_native_at: legacy_created_at, derived_at: legacy_created_at,
          batch_pending_at: legacy_created_at, retry_scheduled_at: nil,
          contract_completed_at: nil, terminal_at: nil
        )

        # complete → contract_complete: completion under the previous contract is a
        # fact, stamped with the fetch that established it. No batch_pending_at — a
        # complete row is not backlog.
        expect(complete).to have_attributes(
          enrichment_status: "complete", enrichment_stage: "contract_complete",
          event_native_at: legacy_seen_at, derived_at: legacy_seen_at,
          batch_pending_at: nil, contract_completed_at: legacy_fetched_at, terminal_at: nil
        )

        # retryable_failure → retry_scheduled, still carrying batch_pending_at so the
        # row remains visible backlog once its preserved next_retry_at clears.
        expect(retryable).to have_attributes(
          enrichment_status: "retryable_failure", enrichment_stage: "retry_scheduled",
          event_native_at: legacy_seen_at, derived_at: legacy_seen_at,
          batch_pending_at: legacy_seen_at, retry_scheduled_at: legacy_updated_at,
          contract_completed_at: nil, terminal_at: nil
        )

        # permanent_failure → terminal, dated by the write that decided it.
        expect(permanent).to have_attributes(
          enrichment_status: "permanent_failure", enrichment_stage: "terminal",
          event_native_at: legacy_seen_at, derived_at: legacy_seen_at,
          batch_pending_at: nil, retry_scheduled_at: nil,
          contract_completed_at: nil, terminal_at: legacy_updated_at
        )
      end
    end
  end

  describe "the stage vocabulary" do
    # event_native / derived / batch_applied are instants (*_at columns), not resting
    # stages — a row that could rest in them would be invisible to both claims.
    it "rejects a stage outside the seven resting stages" do
      create_actor(github_id: staged_actor_ids.first)

      expect_violation(ActiveRecord::CheckViolation) do
        GithubActor.where(github_id: staged_actor_ids.first)
                   .update_all(enrichment_stage: "event_native")
      end
    end
  end

  describe "the down migration" do
    it "removes every staged table, column, index and constraint, then restores them on re-up" do
      migration_context.down(parent_version)
      reset_schema_caches!

      %w[enrichment_batches enrichment_observations github_search_budget].each do |table|
        expect(connection.table_exists?(table)).to be(false), "expected #{table} to be dropped"
      end

      %w[github_actors github_repositories].each do |table|
        columns = connection.columns(table).map(&:name)
        expect(columns).not_to include(*STAGED_ENTITY_COLUMNS)

        index_names = connection.indexes(table).map(&:name)
        expect(index_names).not_to include("index_#{table}_on_stage_fifo")
        expect(index_names).not_to include("index_#{table}_on_leased_until")

        constraint_names = connection.check_constraints(table).map(&:name)
        expect(constraint_names).not_to include("#{table}_enrichment_stage_check")
        expect(constraint_names).not_to include("#{table}_detail_attempts_nonnegative")
      end

      expect(connection.columns("github_actors").map(&:name)).not_to include("account_type")
      expect(connection.columns("github_repositories").map(&:name))
        .not_to include("owner_login", "fork", "archived", "default_branch", "github_created_at")

      # The round trip: re-applying leaves the staged structures present, which is what
      # lets the around hook's ensure restore the suite's schema unconditionally.
      migration_context.migrate
      reset_schema_caches!

      %w[enrichment_batches enrichment_observations github_search_budget].each do |table|
        expect(connection.table_exists?(table)).to be(true), "expected #{table} to be recreated"
      end
      %w[github_actors github_repositories].each do |table|
        expect(connection.columns(table).map(&:name)).to include(*STAGED_ENTITY_COLUMNS)
      end
    end
  end

  private

  def migration_context
    ActiveRecord::Base.connection_pool.migration_context
  end

  # DDL invalidates cached column metadata; every choreography step re-reads it so a
  # model built after the step sees the schema that step produced.
  def reset_schema_caches!
    connection.schema_cache.clear!
    [ GithubActor, GithubRepository, EnrichmentBatch,
      EnrichmentObservation, GithubSearchBudget ].each(&:reset_column_information)
  end

  # Raw SQL, because the pre-staged schema has no staged columns and the entity models'
  # enums cannot even be type-cast against it.
  def insert_legacy_rows!
    rows = [
      # [github_id offset, status, attempts, first_seen_at, fetched_at, last_error]
      [ 0, "pending", 0, nil, nil, nil ],
      [ 1, "complete", 0, legacy_seen_at, legacy_fetched_at, nil ],
      [ 2, "retryable_failure", 2, legacy_seen_at, nil, "GitHub unavailable" ],
      [ 3, "permanent_failure", 3, legacy_seen_at, nil, "HTTP 404" ]
    ]

    rows.each do |offset, status, attempts, seen_at, fetched_at, last_error|
      connection.execute(<<~SQL.squish)
        INSERT INTO github_actors
          (github_id, login, enrichment_status, enrichment_attempts,
           first_seen_at, fetched_at, last_error, created_at, updated_at)
        VALUES
          (#{staged_actor_ids.fetch(offset)}, 'legacy-#{status}',
           #{connection.quote(status)}, #{attempts},
           #{connection.quote(seen_at)}, #{connection.quote(fetched_at)},
           #{connection.quote(last_error)},
           #{connection.quote(legacy_created_at)}, #{connection.quote(legacy_updated_at)})
      SQL

      connection.execute(<<~SQL.squish)
        INSERT INTO github_repositories
          (github_id, full_name, enrichment_status, enrichment_attempts,
           first_seen_at, fetched_at, last_error, created_at, updated_at)
        VALUES
          (#{staged_repository_ids.fetch(offset)}, 'legacy/#{status}',
           #{connection.quote(status)}, #{attempts},
           #{connection.quote(seen_at)}, #{connection.quote(fetched_at)},
           #{connection.quote(last_error)},
           #{connection.quote(legacy_created_at)}, #{connection.quote(legacy_updated_at)})
      SQL
    end
  end
end
