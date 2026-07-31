require "rails_helper"

# §8 step 11's sweep. Its own behaviour is Github::Enrichment::Dispatch's, specified there;
# what this file pins is that the job is that sweep and nothing else — no source lock, no
# request, no reading of push_events, and a summary on its own line.
#
# The recovery property it exists for — work committed before a crash but never enqueued —
# is spec/recovery/pending_enrichment_recovery_spec.rb.
RSpec.describe ReconcilePendingEnrichmentsJob do
  before { active_budget_window(now: frozen_time) }

  it "reconciles, and reports what it scheduled on the job's line" do
    create_actor(github_id: 583_231, last_seen_at: Time.current)
    allow(Rails.logger).to receive(:info)

    job = described_class.new
    expect { job.perform_now }.to have_enqueued_job(EnrichActorJob).exactly(:once)

    expect(Rails.logger).to have_received(:info).with(
      hash_including(event: "job.completed", job_id: job.job_id, reason: "reconcile", actor_enqueued: 1)
    )
  end

  it "enqueues nothing when there is nothing durable to do" do
    expect { described_class.new.perform_now }.not_to have_enqueued_job
  end

  # §8: "a small, entity-scoped set, not N event rows per entity". Held structurally — the
  # sweep never reads push_events at all — so this asserts the structure rather than a count.
  it "never reads the event table it is recovering work for" do
    create_actor(github_id: 583_231, last_seen_at: Time.current)
    tables = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      tables << payload[:sql]
    end

    begin
      described_class.new.perform_now
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    expect(tables.grep(/push_events/)).to be_empty
  end

  it "takes no lock and makes no request" do
    create_actor(github_id: 583_231, last_seen_at: Time.current)
    expect(Github::SourceLock).not_to receive(:acquire)
    expect(Github::RequestGate).not_to receive(:hold)

    described_class.new.perform_now

    expect(WebMock).not_to have_requested(:any, //)
    expect(Github::LockOrder.held_keys).to be_empty
  end
end
