# §8 step 11 — "Reconcile entities whose enrichment was not scheduled or completed" — as the
# recurring sweep behind §2A's outbox-style recovery. config/recurring.yml fires it every 60
# seconds.
#
# **This is the crash-recovery mechanism, and its input is committed entity state.** The
# post-commit enqueue in Github::IngestionRunner is a hint; a process killed between the
# COMMIT and the enqueue, a worker that was down for an hour, a job that failed permanently
# — all of them lose the hint, and none of them lose the work, because the entity rows still
# say `pending` and the partial index that answers that predicate has existed since PR 3.
#
# **Entity-scoped, structurally.** It reads github_actors, github_repositories and one
# github_api_budget row through Github::Enrichment::Dispatch, and never push_events. §8's
# words are "a small, entity-scoped set, not N event rows per entity": fifty events
# referencing one actor are one candidate here, not fifty.
#
# It enqueues nothing when nothing is claimable, and nothing while §9's global block or the
# derived class block is in force — so an exhausted window costs one indexed EXISTS per class
# per minute rather than a queue full of cycles the ledger would refuse.
class ReconcilePendingEnrichmentsJob < ApplicationJob
  def perform
    @outcome = Github::Enrichment::Dispatch.call(reason: "reconcile")
  end
end
