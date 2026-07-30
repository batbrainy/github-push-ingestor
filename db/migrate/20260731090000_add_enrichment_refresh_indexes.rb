# PR 3 shipped index_*_on_enrichment_candidates — (next_retry_at, last_seen_at) partial on
# CANDIDATE_STATUSES — which serves the never-enriched pool exactly. PR 7 introduces the
# *second* pool §10 defines: TTL-stale refreshes, which are `complete` rows and therefore
# excluded from that index by its own predicate.
#
# Without this index the refresh query has none, and it seq-scans a table whose population
# is overwhelmingly the wrong shape: §10's demand arithmetic puts candidate arrival at
# roughly 2,000 rows an hour against at most `enrichment_allowance` completions (40), so
# the scan reads thousands of irrelevant rows to find tens of relevant ones. That is the
# case a partial index exists for.
#
# Column order is (fetched_at, next_retry_at) because fetched_at carries both the range
# predicate and the ORDER BY, so the scan is already ordered and stops at the first match;
# next_retry_at resolves the remaining predicate in-index for the common NULL case.
#
# Deliberately not algorithm: :concurrently. That needs disable_ddl_transaction!, which
# complicates the compose `setup` service's db:prepare, and at these table sizes the lock
# is sub-second. A production-scale rollout against a populated table would use the
# concurrent form; saying so is more honest than pretending the tradeoff is not there.
class AddEnrichmentRefreshIndexes < ActiveRecord::Migration[8.1]
  def change
    add_index :github_actors, %i[fetched_at next_retry_at],
              where: "enrichment_status = 'complete'",
              name: "index_github_actors_on_enrichment_refresh"

    add_index :github_repositories, %i[fetched_at next_retry_at],
              where: "enrichment_status = 'complete'",
              name: "index_github_repositories_on_enrichment_refresh"
  end
end
