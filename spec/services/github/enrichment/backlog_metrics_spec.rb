require "rails_helper"

RSpec.describe Github::Enrichment::BacklogMetrics do
  let(:now) { frozen_time }

  def capture = described_class.capture(now: now)

  it "counts pending and retryable rows even when their next attempt is deferred" do
    create_actor(github_id: 1, enrichment_status: "pending")
    create_actor(github_id: 2, enrichment_status: "retryable_failure",
                 next_retry_at: now + 3600)
    create_actor(github_id: 3, enrichment_status: "complete", fetched_at: now)
    create_actor(github_id: 4, enrichment_status: "permanent_failure")

    expect(capture.actor).to have_attributes(
      status_counts: {
        "pending" => 1, "complete" => 1,
        "retryable_failure" => 1, "permanent_failure" => 1
      },
      backlog_count: 2
    )
  end

  it "uses created_at for the oldest wait, matching FIFO selection" do
    create_actor(github_id: 1, created_at: now - 300, last_seen_at: now)
    create_actor(github_id: 2, created_at: now - 900, last_seen_at: now - 10)

    expect(capture.actor).to have_attributes(
      backlog_count: 2,
      oldest_pending_at: now - 900,
      oldest_pending_age_seconds: 900
    )
  end

  it "excludes older terminal rows from the oldest backlog wait" do
    create_actor(github_id: 1, enrichment_status: "complete",
                 fetched_at: now, created_at: now - 1800)
    create_actor(github_id: 2, enrichment_status: "permanent_failure",
                 created_at: now - 1200)
    create_actor(github_id: 3, enrichment_status: "pending",
                 created_at: now - 300)

    expect(capture.actor).to have_attributes(
      backlog_count: 1,
      oldest_pending_at: now - 300,
      oldest_pending_age_seconds: 300
    )
  end

  it "reports each entity class independently" do
    create_actor(github_id: 1, created_at: now - 300)
    create_repository(github_id: 2, created_at: now - 600)

    expect(capture.actor).to have_attributes(backlog_count: 1,
                                             oldest_pending_at: now - 300)
    expect(capture.repository).to have_attributes(backlog_count: 1,
                                                  oldest_pending_at: now - 600)
  end

  it "reports nil oldest metrics for an empty backlog" do
    entry = capture.actor

    expect(entry).to have_attributes(backlog_count: 0, oldest_pending_at: nil,
                                     oldest_pending_age_seconds: nil)
  end

  it "clamps harmless database-clock skew instead of reporting a negative age" do
    create_actor(github_id: 1, created_at: now + 1)

    expect(capture.actor.oldest_pending_age_seconds).to eq(0)
  end

  it "reads persisted state without writing or initiating a GitHub request" do
    create_actor(github_id: 1)
    transport = fixture_transport
    allow(Github).to receive(:transport).and_return(transport)

    expect(write_statements { capture }).to be_empty
    expect(transport.requests).to be_empty
  end

  it "captures counts and the oldest row in one aggregate statement per entity class" do
    create_actor(github_id: 1)
    create_repository(github_id: 2)

    statements = capture_sql { capture }
    actor_reads = statements.grep(/FROM "github_actors"/)
    repository_reads = statements.grep(/FROM "github_repositories"/)

    expect(actor_reads.one?).to be(true)
    expect(repository_reads.one?).to be(true)
    expect(actor_reads.first).to include("COUNT(CASE WHEN", "MIN(CASE WHEN")
    expect(repository_reads.first).to include("COUNT(CASE WHEN", "MIN(CASE WHEN")
  end
end
