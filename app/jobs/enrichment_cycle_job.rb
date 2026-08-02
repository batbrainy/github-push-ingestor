# One staged-enrichment cycle (IMPLEMENTATION_PLAN.md §5, Appendix G).
#
# It takes no arguments and no entity class: Github::Enrichment::CycleRunner works both
# lanes itself — Search batches while the search ledger grants, then detail fallbacks
# while the core allowance grants — choosing lanes through the weighted schedule and
# FOR UPDATE SKIP LOCKED claims in durable FIFO order. One looping job rather than a
# job per request, because pacing (6s) is far finer than the 60-second tick and the
# enrichment queue deliberately has one thread.
#
# Duplicate deliveries are harmless by construction: a surplus cycle's first admission
# check or claim finds pacing, exhaustion, or no claimable work, and the cycle exits in
# milliseconds having created no batch row and spent no budget.
#
# It never takes a source lock (§8 step 1: enrichment takes only the request gate), and
# Github::LockOrder enforces that structurally.
class EnrichmentCycleJob < ApplicationJob
  # Enrichment is deliberately isolated from polling and reconciliation. A deep durable
  # entity backlog may keep this queue busy for many rate-limit windows, but it must
  # never delay the control tick that discovers more committed work or the poller that
  # creates it.
  queue_as :enrichment

  def perform
    @outcome = Github::Enrichment::CycleRunner.new.call.to_log
  end
end
