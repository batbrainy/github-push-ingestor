require "rails_helper"
require Rails.root.join("db/migrate/20260802000000_remove_skipped_budget_from_enrichment").to_s

RSpec.describe RemoveSkippedBudgetFromEnrichment, type: :migration do
  self.use_transactional_tests = false

  ACTOR_IDS = [ 99_100_001, 99_100_002 ].freeze
  REPOSITORY_IDS = [ 99_200_001, 99_200_002 ].freeze

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  around do |example|
    previous_verbose = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false

    begin
      example.run
    ensure
      restore_current_schema!
      GithubActor.where(github_id: ACTOR_IDS).delete_all
      GithubRepository.where(github_id: REPOSITORY_IDS).delete_all
      ActiveRecord::Migration.verbose = previous_verbose
    end
  end

  it "restores every discarded row to the durable FIFO and removes the old state" do
    migration.migrate(:down)
    reset_entity_schema_cache!
    insert_legacy_rows!

    migration.migrate(:up)
    reset_entity_schema_cache!

    expect(GithubActor.where(github_id: ACTOR_IDS).order(:github_id).pluck(:enrichment_status))
      .to eq(%w[pending retryable_failure])
    expect(GithubRepository.where(github_id: REPOSITORY_IDS).order(:github_id).pluck(:enrichment_status))
      .to eq(%w[pending retryable_failure])

    attempted = GithubActor.find_by!(github_id: ACTOR_IDS.last)
    expect(attempted).to have_attributes(enrichment_attempts: 2, last_error: "GitHub unavailable")
    expect(attempted.next_retry_at).to be <= Time.current

    %w[github_actors github_repositories].each do |table|
      expect(connection.column_exists?(table, :skipped_at)).to be(false)

      index = connection.indexes(table)
                        .find { _1.name == "index_#{table}_on_enrichment_candidates" }
      expect(index.columns).to eq(%w[created_at id])
      expect(index.where).to include("pending", "retryable_failure")
    end

    expect_violation(ActiveRecord::CheckViolation) do
      GithubActor.where(github_id: ACTOR_IDS.first)
                 .update_all(enrichment_status: "skipped_budget")
    end
  end

  private

  def insert_legacy_rows!
    now = connection.quote(Time.current - 2.days)
    future = connection.quote(Time.current + 1.day)

    connection.execute(<<~SQL)
      INSERT INTO github_actors
        (github_id, login, enrichment_status, enrichment_attempts, next_retry_at,
         last_error, created_at, updated_at, skipped_at)
      VALUES
        (#{ACTOR_IDS.first}, 'legacy-pending', 'skipped_budget', 0, #{future},
         NULL, #{now}, #{now}, #{now}),
        (#{ACTOR_IDS.last}, 'legacy-retry', 'skipped_budget', 2, #{future},
         'GitHub unavailable', #{now}, #{now}, #{now})
    SQL

    connection.execute(<<~SQL)
      INSERT INTO github_repositories
        (github_id, full_name, enrichment_status, enrichment_attempts, next_retry_at,
         last_error, created_at, updated_at, skipped_at)
      VALUES
        (#{REPOSITORY_IDS.first}, 'legacy/pending', 'skipped_budget', 0, #{future},
         NULL, #{now}, #{now}, #{now}),
        (#{REPOSITORY_IDS.last}, 'legacy/retry', 'skipped_budget', 2, #{future},
         'GitHub unavailable', #{now}, #{now}, #{now})
    SQL
  end

  def restore_current_schema!
    if connection.column_exists?(:github_actors, :skipped_at) ||
       connection.column_exists?(:github_repositories, :skipped_at)
      migration.migrate(:up)
    end

    reset_entity_schema_cache!
  end

  def reset_entity_schema_cache!
    connection.schema_cache.clear!
    GithubActor.reset_column_information
    GithubRepository.reset_column_information
  end
end
