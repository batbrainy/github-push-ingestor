class RemoveSkippedBudgetFromEnrichment < ActiveRecord::Migration[8.1]
  TABLES = %i[github_actors github_repositories].freeze
  STATUSES = %w[pending complete retryable_failure permanent_failure].freeze

  def up
    TABLES.each do |table|
      restore_skipped_rows(table)
      replace_status_constraint(table, STATUSES)
      replace_candidate_index(table, %i[created_at id])
      remove_column table, :skipped_at, :datetime
    end
  end

  def down
    TABLES.each do |table|
      add_column table, :skipped_at, :datetime
      replace_status_constraint(table, STATUSES + [ "skipped_budget" ])
      replace_candidate_index(table, %i[next_retry_at last_seen_at])
    end
  end

  private

  # AgeOut previously erased whether a skipped row had been pending for its first attempt
  # or waiting after a retryable failure. Attempt history is the remaining durable signal,
  # so untouched rows return to pending and attempted rows return to retryable_failure.
  # Either way the row is immediately eligible unless its preserved retry instant is
  # already earlier. Quota delay can no longer turn either state into a terminal one.
  def restore_skipped_rows(table)
    execute <<~SQL.squish
      UPDATE #{table}
         SET enrichment_status = CASE
               WHEN enrichment_attempts > 0 OR last_error IS NOT NULL
                 THEN 'retryable_failure'
               ELSE 'pending'
             END,
             next_retry_at = CASE
               WHEN next_retry_at > CURRENT_TIMESTAMP THEN CURRENT_TIMESTAMP
               ELSE next_retry_at
             END,
             updated_at = GREATEST(updated_at, CURRENT_TIMESTAMP)
       WHERE enrichment_status = 'skipped_budget'
    SQL
  end

  def replace_status_constraint(table, statuses)
    name = "#{table}_enrichment_status_check"
    remove_check_constraint table, name: name
    quoted = statuses.map { |status| connection.quote(status) }.join(", ")
    add_check_constraint table, "enrichment_status IN (#{quoted})", name: name
  end

  def replace_candidate_index(table, columns)
    name = "index_#{table}_on_enrichment_candidates"
    remove_index table, name: name
    add_index table, columns,
              where: "enrichment_status IN ('pending', 'retryable_failure')",
              name: name
  end
end
