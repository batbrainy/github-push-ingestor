# PR 8's recurring tick asks a question nothing asked before: "which sources might be due
# right now?" (EventSource.poll_due). Until this PR, every path reached exactly one row
# through Github::Ingestion::SourceProvisioner.ensure!, so event_sources carried no index
# at all — and a PR 3 spec asserted that absence deliberately, so that adding the query and
# adding its index would land in the same reviewable change.
#
# Column order is (source_type, next_poll_at): source_type is the equality predicate and
# next_poll_at carries the range. The partial predicate is the scope's remaining WHERE, so
# the index covers the whole query and the two cannot drift without the schema spec
# noticing.
#
# The table is tiny — one row per mode today — so this index buys no measurable time now.
# It is here because the query is written to survive §9's "multiple event sources", and an
# index added with its query is checkable, while one added later is archaeology.
#
# Same deliberate omission as AddEnrichmentRefreshIndexes: not algorithm: :concurrently,
# because disable_ddl_transaction! complicates the compose `setup` service's db:prepare and
# the lock here is sub-second at any plausible size.
class AddPollDueIndexToEventSources < ActiveRecord::Migration[8.1]
  def change
    add_index :event_sources, %i[source_type next_poll_at],
              where: "enabled AND status = 'idle'",
              name: "index_event_sources_on_poll_due"
  end
end
