require "rails_helper"

RSpec.describe Github::Enrichment::BacklogMetrics do
  let(:now) { frozen_time }

  def capture(configuration: Github.configuration)
    described_class.capture(now: now, configuration: configuration)
  end

  describe "status counts" do
    it "drops statuses with no rows, publishing only counted facts" do
      create_actor(github_id: 1)

      expect(capture.actor.status_counts).to eq("pending" => 1)
    end

    it "counts pending and retryable rows even when their next attempt is deferred" do
      create_actor(github_id: 1, enrichment_status: "pending")
      create_actor(github_id: 2, enrichment_status: "retryable_failure",
                   enrichment_stage: "retry_scheduled", next_retry_at: now + 3600)
      create_actor(github_id: 3, enrichment_status: "complete",
                   enrichment_stage: "contract_complete", fetched_at: now)
      create_actor(github_id: 4, enrichment_status: "permanent_failure",
                   enrichment_stage: "terminal")

      expect(capture.actor).to have_attributes(
        status_counts: {
          "pending" => 1, "complete" => 1,
          "retryable_failure" => 1, "permanent_failure" => 1
        },
        backlog_count: 2
      )
    end
  end

  describe "stage counts and oldest instants" do
    # The opposite convention from status_counts, deliberately: the payload publishes
    # every stage, so a consumer never has to distinguish "absent key" from "counted
    # zero" when reading the pipeline.
    it "keeps all seven stages with their zeros" do
      create_actor(github_id: 1, enrichment_stage: "detail_pending",
                   detail_pending_at: now - 60)

      expect(capture.actor.stage_counts).to eq(
        "batch_pending" => 0, "batch_in_flight" => 0, "detail_pending" => 1,
        "detail_in_flight" => 0, "retry_scheduled" => 0, "contract_complete" => 0,
        "terminal" => 0
      )
    end

    # created_at is the immutable FIFO clock BatchClaim orders by, so "oldest" here is
    # the row a worker would actually choose next from that stage.
    it "reports each stage's oldest created_at, nil where the stage is empty" do
      create_actor(github_id: 1, created_at: now - 300)
      create_actor(github_id: 2, created_at: now - 900)
      create_actor(github_id: 3, enrichment_stage: "detail_pending",
                   detail_pending_at: now - 60, created_at: now - 600)

      stage_oldest = capture.actor.stage_oldest

      expect(stage_oldest.fetch("batch_pending")).to eq(now - 900)
      expect(stage_oldest.fetch("detail_pending")).to eq(now - 600)
      expect(stage_oldest.fetch("terminal")).to be_nil
      expect(stage_oldest.keys).to eq(Enrichable::ENRICHMENT_STAGES)
    end
  end

  describe "the contract backlog" do
    # Appendix G's rule: not yet at the useful-data contract or a terminal outcome, and
    # not a completed row transiting a refresh. A complete row mid-refresh sits in
    # batch_in_flight or detail_pending without owing the contract anything.
    it "excludes complete-status refresh transits and terminal rows" do
      create_actor(github_id: 1, enrichment_status: "pending",
                   enrichment_stage: "batch_pending")
      create_actor(github_id: 2, enrichment_status: "retryable_failure",
                   enrichment_stage: "retry_scheduled", next_retry_at: now + 60)
      create_actor(github_id: 3, enrichment_status: "pending",
                   enrichment_stage: "detail_in_flight", detail_pending_at: now - 60)
      create_actor(github_id: 4, enrichment_status: "complete",
                   enrichment_stage: "contract_complete", fetched_at: now)
      create_actor(github_id: 5, enrichment_status: "complete",
                   enrichment_stage: "batch_in_flight", fetched_at: now - 90_000)
      create_actor(github_id: 6, enrichment_status: "complete",
                   enrichment_stage: "detail_pending", detail_pending_at: now - 60,
                   fetched_at: now - 90_000)
      create_actor(github_id: 7, enrichment_status: "permanent_failure",
                   enrichment_stage: "terminal", terminal_at: now - 60)

      expect(capture.actor).to have_attributes(contract_backlog_count: 3,
                                               backlog_count: 3)
    end
  end

  describe "the oldest pending wait" do
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
                   enrichment_stage: "contract_complete",
                   fetched_at: now, created_at: now - 1800)
      create_actor(github_id: 2, enrichment_status: "permanent_failure",
                   enrichment_stage: "terminal", created_at: now - 1200)
      create_actor(github_id: 3, enrichment_status: "pending",
                   created_at: now - 300)

      expect(capture.actor).to have_attributes(
        backlog_count: 1,
        oldest_pending_at: now - 300,
        oldest_pending_age_seconds: 300
      )
    end

    it "reports nil oldest metrics for an empty backlog" do
      expect(capture.actor).to have_attributes(backlog_count: 0, oldest_pending_at: nil,
                                               oldest_pending_age_seconds: nil)
    end

    it "clamps harmless database-clock skew instead of reporting a negative age" do
      create_actor(github_id: 1, created_at: now + 1)

      expect(capture.actor.oldest_pending_age_seconds).to eq(0)
    end
  end

  describe "the windowed flow counters" do
    # The three clocks are deliberately different columns: arrival is the row's
    # immutable created_at, completion is contract_completed_at, and a terminal outcome
    # is terminal_at. Each counter answers only its own clock.
    it "counts arrivals strictly inside the trailing window" do
      create_actor(github_id: 1, created_at: now - 3599)
      create_actor(github_id: 2, created_at: now - 3600)
      create_actor(github_id: 3, created_at: now - 3601)

      metrics = capture

      expect(metrics.window_seconds).to eq(3600)
      expect(metrics.actor.arrivals).to eq(1)
    end

    it "counts completions and terminals on their own clocks, not on arrival" do
      create_actor(github_id: 1, enrichment_status: "complete",
                   enrichment_stage: "contract_complete",
                   created_at: now - 7200, contract_completed_at: now - 60)
      create_actor(github_id: 2, enrichment_status: "permanent_failure",
                   enrichment_stage: "terminal",
                   created_at: now - 7200, terminal_at: now - 10)
      create_actor(github_id: 3, enrichment_status: "complete",
                   enrichment_stage: "contract_complete",
                   created_at: now - 9000, contract_completed_at: now - 7200)

      expect(capture.actor).to have_attributes(arrivals: 0, completions: 1, terminals: 1)
    end

    it "reads the window from the configuration it was given" do
      create_actor(github_id: 1, created_at: now - 700)
      configuration = configuration_with(ENRICHMENT_METRICS_WINDOW_SECONDS: "600")

      expect(capture(configuration: configuration))
        .to have_attributes(window_seconds: 600)
      expect(capture(configuration: configuration).actor.arrivals).to eq(0)
      expect(capture.actor.arrivals).to eq(1)
    end

    # The throughput sample truncates to this instant, so it spans every row the table
    # has ever held — terminal ones included.
    it "reports the earliest created_at across every row, whatever its outcome" do
      create_actor(github_id: 1, enrichment_status: "permanent_failure",
                   enrichment_stage: "terminal", created_at: now - 7200)
      create_actor(github_id: 2, created_at: now - 300)

      expect(capture.actor.earliest_created_at).to eq(now - 7200)
      expect(capture.repository.earliest_created_at).to be_nil
    end
  end

  it "reports each entity class independently" do
    create_actor(github_id: 1, created_at: now - 300)
    create_repository(github_id: 2, created_at: now - 600)

    expect(capture.actor).to have_attributes(backlog_count: 1,
                                             oldest_pending_at: now - 300)
    expect(capture.repository).to have_attributes(backlog_count: 1,
                                                  oldest_pending_at: now - 600)
  end

  it "reads persisted state without writing or initiating a GitHub request" do
    create_actor(github_id: 1)
    transport = fixture_transport
    allow(Github).to receive(:transport).and_return(transport)

    expect(write_statements { capture }).to be_empty
    expect(transport.requests).to be_empty
  end

  # A worker may commit between statements, so numbers taken from separate reads could
  # publish a combination that never existed. One aggregate per table is the guarantee,
  # and counting the SELECTs is how it stays true under refactoring.
  it "captures everything in exactly two SELECT statements, one per entity table" do
    create_actor(github_id: 1, enrichment_status: "complete",
                 enrichment_stage: "contract_complete", contract_completed_at: now - 60)
    create_repository(github_id: 2)

    selects = capture_sql { capture }.grep(/\A\s*SELECT/i)

    expect(selects.length).to eq(2)
    expect(selects.count { |statement| statement.include?('FROM "github_actors"') }).to eq(1)
    expect(selects.count { |statement| statement.include?('FROM "github_repositories"') }).to eq(1)
  end
end
