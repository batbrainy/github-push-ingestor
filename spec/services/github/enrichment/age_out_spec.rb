require "rails_helper"

RSpec.describe Github::Enrichment::AgeOut do
  subject(:age_out) { described_class.new(configuration: configuration_with) }

  let(:now) { frozen_time }
  let(:aged) { now - 3601 }
  let(:actor_type) { Github::Enrichment::EntityType.fetch(:actor) }

  def sweep = age_out.call(now: now)

  describe "the eligibility window (plan §10, B8)" do
    it "skips a candidate whose activity aged past the window" do
      actor = create_actor(github_id: 1, last_seen_at: aged)

      expect(sweep.fetch(actor_type)).to eq(1)
      expect(actor.reload).to have_attributes(enrichment_status: "skipped_budget", skipped_at: now)
    end

    it "keeps a candidate that is still inside the window" do
      actor = create_actor(github_id: 1, last_seen_at: now - 3599)

      expect(sweep.fetch(actor_type)).to eq(0)
      expect(actor.reload.enrichment_status).to eq("pending")
    end

    it "skips a retryable failure too, which is the other half of the candidate set" do
      create_actor(github_id: 1, last_seen_at: aged, enrichment_status: "retryable_failure")

      expect(sweep.fetch(actor_type)).to eq(1)
    end

    it "never touches a complete or terminally failed row, which are not backlog" do
      complete = create_actor(github_id: 1, last_seen_at: aged, enrichment_status: "complete",
                              fetched_at: aged)
      permanent = create_actor(github_id: 2, last_seen_at: aged, enrichment_status: "permanent_failure")

      sweep

      expect(complete.reload.enrichment_status).to eq("complete")
      expect(permanent.reload.enrichment_status).to eq("permanent_failure")
    end

    # The totality argument behind B8: without COALESCE such a row is neither eligible
    # (NULL > floor is NULL) nor ageable, and it would sit pending forever.
    it "keeps a stub with no last_seen_at until one window after it was created" do
      fresh = create_actor(github_id: 1, last_seen_at: nil)
      old = create_actor(github_id: 2, last_seen_at: nil, created_at: aged)

      sweep

      expect(fresh.reload.enrichment_status).to eq("pending")
      expect(old.reload.enrichment_status).to eq("skipped_budget")
    end

    it "sweeps both classes on every call, so neither backlog can grow unattended" do
      create_actor(github_id: 1, last_seen_at: aged)
      create_repository(github_id: 2, last_seen_at: aged)

      expect(sweep.values.sum).to eq(2)
      expect(GithubRepository.sole.enrichment_status).to eq("skipped_budget")
    end
  end

  describe "what it deliberately leaves alone" do
    # The same due predicate the two candidate pools use — one clause, so a leased row,
    # a backed-off row and a secondary-limit deferral are all excluded at once.
    it "never skips an entity another worker is currently enriching" do
      actor = create_actor(github_id: 1, last_seen_at: aged, next_retry_at: now + 600)

      expect(sweep.fetch(actor_type)).to eq(0)
      expect(actor.reload.enrichment_status).to eq("pending")
    end

    it "never skips an entity whose backoff has not expired" do
      create_actor(github_id: 1, last_seen_at: aged, next_retry_at: now + 60)

      expect(sweep.fetch(actor_type)).to eq(0)
    end

    # A skip is not an attempt and knows nothing about failures.
    it "leaves the attempt count and the last error alone" do
      actor = create_actor(github_id: 1, last_seen_at: aged, enrichment_attempts: 2, last_error: "boom")

      sweep

      expect(actor.reload).to have_attributes(enrichment_attempts: 2, last_error: "boom")
    end

    # This is what makes reactivation's "immediately due" property provable: the WHERE
    # requires next_retry_at to be NULL or already past, so no skipped_budget row can carry
    # a future instant, and Enrichable#reactivate_skipped! needs no clearing clause.
    it "leaves next_retry_at alone, so a reactivated entity is provably due at once" do
      create_actor(github_id: 1, last_seen_at: aged, next_retry_at: now - 60)

      sweep

      expect(GithubActor.where(enrichment_status: "skipped_budget").where(next_retry_at: now..)).to be_empty
    end
  end

  describe "the bounded batch" do
    # An unbounded UPDATE over §10's ~2,000 candidates an hour would eventually hold
    # hundreds of thousands of row locks in one statement. The ordering makes the residue
    # always the *least* overdue, so progress is monotone.
    it "sweeps the most overdue candidates first when the batch is bounded" do
      stub_const("#{described_class}::BATCH_SIZE", 1)
      recent = create_actor(github_id: 1, last_seen_at: aged)
      oldest = create_actor(github_id: 2, last_seen_at: now - 100_000)

      sweep

      expect(oldest.reload.enrichment_status).to eq("skipped_budget")
      expect(recent.reload.enrichment_status).to eq("pending")
    end

    it "finishes the backlog across successive calls" do
      stub_const("#{described_class}::BATCH_SIZE", 1)
      create_actor(github_id: 1, last_seen_at: aged)
      create_actor(github_id: 2, last_seen_at: aged)

      2.times { sweep }

      expect(GithubActor.where(enrichment_status: "skipped_budget").count).to eq(2)
    end
  end

  describe "logging" do
    # §11 puts "skipped" at INFO, but one line per row would emit thousands in a single
    # sweep — the volume argument BudgetLedger#log_class_exhausted already makes.
    it "logs one summary per class rather than one line per row" do
      allow(Rails.logger).to receive(:info)
      3.times { |index| create_actor(github_id: index, last_seen_at: aged) }

      sweep

      expect(Rails.logger).to have_received(:info)
        .with(hash_including(event: "enrichment.aged_out", entity_type: :actor, skipped_count: 3)).once
    end

    it "says nothing at all when a class had nothing to skip" do
      allow(Rails.logger).to receive(:info)

      sweep

      expect(Rails.logger).not_to have_received(:info).with(hash_including(event: "enrichment.aged_out"))
    end
  end
end
