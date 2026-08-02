# One actor enrichment cycle (IMPLEMENTATION_PLAN.md §5, §8 step 10).
#
# It takes no actor id, and that is the design rather than an omission:
# Github::EnrichmentRunner enriches at most one entity per call and *chooses* it through
# §10's fairness policy and a FOR UPDATE SKIP LOCKED lease, in durable FIFO order. An
# id-addressed job would have to bypass that ordering to honour its argument, which is how a
# repository flood starves actors. So the job says "do one actor's worth of work" and the
# runner decides whose — which is also why a duplicate delivery is harmless: it is one
# more cycle, and it finds either different work or none.
#
# It never takes a source lock (§8 step 1: "enrichment jobs skip this step — they take only
# the request gate"), and Github::LockOrder enforces that structurally.
class EnrichActorJob < ApplicationJob
  # Enrichment is deliberately isolated from polling and reconciliation. A deep durable
  # entity backlog may keep this queue busy for many rate-limit windows, but it must never
  # delay the control tick that discovers more committed work or the poller that creates it.
  queue_as :enrichment

  def perform
    result = Github::EnrichmentRunner.new.call(entity_class: GithubActor)

    # idle and deferred are ordinary outcomes, not errors: nothing was eligible, or the
    # ledger refused. Github::EnrichmentRunner already logged the cycle; this joins it to the
    # job. Errors::FixtureMiss and anything unexpected propagate — the runner released the
    # lease before re-raising, and ApplicationJob turns it into job.failed.
    @outcome = { entity_type: result.entity_type, github_actor_id: result.github_id,
                 enrichment_outcome: result.status }.compact
  end
end
