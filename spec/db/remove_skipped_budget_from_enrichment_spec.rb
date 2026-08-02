require "rails_helper"
require Rails.root.join("db/migrate/20260802000000_remove_skipped_budget_from_enrichment").to_s

# Choreography note, shared with add_staged_batch_enrichment_spec.rb: this migration no
# longer sits at the top of the ladder — 20260802010000 is stacked above it — so its
# down/up cycle must go through ActiveRecord::MigrationContext, which reverts the staged
# migration *first* and replays both in version order afterwards. A bare
# Migration#migrate(:down) on this class alone would exercise it against a schema shape
# it never ran on, and would leave schema_migrations lying about what is applied. The
# around hook's ensure migrates back to the top whatever the example did, so no later
# randomly-ordered spec inherits a half-reverted database.
#
# While the schema sits below the staged migration the entity models are unusable
# (their enrichment_stage enum has no backing column), so the legacy rows are seeded
# with raw SQL and every assertion runs after the ladder is fully re-applied. The
# restored statuses survive that composition untouched: 20260802010000 maps them onto
# stages, it never rewrites them.
RSpec.describe RemoveSkippedBudgetFromEnrichment, type: :migration do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }

  # The version below this migration: `down(parent_version)` reverts the staged
  # migration and then this one, restoring the pre-removal schema this spec seeds.
  let(:parent_version) { 20260731120000 }

  let(:skipped_actor_ids) { [ 99_100_001, 99_100_002 ] }
  let(:skipped_repository_ids) { [ 99_200_001, 99_200_002 ] }

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
      GithubActor.where(github_id: skipped_actor_ids).delete_all
      GithubRepository.where(github_id: skipped_repository_ids).delete_all
      ActiveRecord::Migration.verbose = previous_verbose
    end
  end

  it "restores every discarded row to the durable FIFO and removes the old state" do
    migration_context.down(parent_version)
    reset_schema_caches!
    insert_legacy_rows!

    migration_context.migrate
    reset_schema_caches!

    expect(GithubActor.where(github_id: skipped_actor_ids).order(:github_id).pluck(:enrichment_status))
      .to eq(%w[pending retryable_failure])
    expect(GithubRepository.where(github_id: skipped_repository_ids).order(:github_id).pluck(:enrichment_status))
      .to eq(%w[pending retryable_failure])

    attempted = GithubActor.find_by!(github_id: skipped_actor_ids.last)
    expect(attempted).to have_attributes(enrichment_attempts: 2, last_error: "GitHub unavailable")
    expect(attempted.next_retry_at).to be <= Time.current

    # The staged migration above carries the restored outcomes into the staged FIFO:
    # quota delay ends as actionable backlog, never as a terminal state.
    expect(GithubActor.where(github_id: skipped_actor_ids).order(:github_id).pluck(:enrichment_stage))
      .to eq(%w[batch_pending retry_scheduled])

    %w[github_actors github_repositories].each do |table|
      expect(connection.column_exists?(table, :skipped_at)).to be(false)

      index = connection.indexes(table)
                        .find { _1.name == "index_#{table}_on_enrichment_candidates" }
      expect(index.columns).to eq(%w[created_at id])
      expect(index.where).to include("pending", "retryable_failure")
    end

    expect_violation(ActiveRecord::CheckViolation) do
      GithubActor.where(github_id: skipped_actor_ids.first)
                 .update_all(enrichment_status: "skipped_budget")
    end
  end

  private

  def migration_context
    ActiveRecord::Base.connection_pool.migration_context
  end

  def insert_legacy_rows!
    now = connection.quote(Time.current - 2.days)
    future = connection.quote(Time.current + 1.day)

    connection.execute(<<~SQL)
      INSERT INTO github_actors
        (github_id, login, enrichment_status, enrichment_attempts, next_retry_at,
         last_error, created_at, updated_at, skipped_at)
      VALUES
        (#{skipped_actor_ids.first}, 'legacy-pending', 'skipped_budget', 0, #{future},
         NULL, #{now}, #{now}, #{now}),
        (#{skipped_actor_ids.last}, 'legacy-retry', 'skipped_budget', 2, #{future},
         'GitHub unavailable', #{now}, #{now}, #{now})
    SQL

    connection.execute(<<~SQL)
      INSERT INTO github_repositories
        (github_id, full_name, enrichment_status, enrichment_attempts, next_retry_at,
         last_error, created_at, updated_at, skipped_at)
      VALUES
        (#{skipped_repository_ids.first}, 'legacy/pending', 'skipped_budget', 0, #{future},
         NULL, #{now}, #{now}, #{now}),
        (#{skipped_repository_ids.last}, 'legacy/retry', 'skipped_budget', 2, #{future},
         'GitHub unavailable', #{now}, #{now}, #{now})
    SQL
  end

  def reset_schema_caches!
    connection.schema_cache.clear!
    [ GithubActor, GithubRepository, EnrichmentBatch,
      EnrichmentObservation, GithubSearchBudget ].each(&:reset_column_information)
  end
end
