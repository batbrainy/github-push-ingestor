# PR 3 left event_sources.status deliberately unconstrained: "no vocabulary for it is
# defined anywhere in the plan, and PR 6 owns the poll state machine — inventing a value
# set now would pre-empt that decision." PR 6 is that PR, so the vocabulary and its
# constraint land together.
#
# Two values, because every other candidate is already represented elsewhere and a second
# representation is a second thing that can disagree:
#
#   idle   — healthy and schedulable. A completed poll, a 304, and every deferral all
#            leave it here. Whether a poll may happen *now* is effective_poll_time's
#            answer (§9), derived from four independent columns; storing a "deferred"
#            status beside them would be exactly the collapsed timestamp §9 forbids.
#   failed — a permanent 4xx on /events took the source out of service (§10). Not
#            derivable: consecutive_failures counts *retryable* failures and resets on
#            success, while a permanent client error is terminal on first occurrence.
#
# `enabled` keeps its own distinct meaning — an operator turned this off — so a permanent
# 4xx sets status only and never touches it.
#
# Safe on any existing database: SourceProvisioner has only ever written 'idle'.
class AddStatusCheckToEventSources < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :event_sources, "status IN ('idle', 'failed')",
                         name: "event_sources_status_known"
  end
end
