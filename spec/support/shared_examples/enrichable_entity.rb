# github_actors and github_repositories carry an identical enrichment state machine
# (IMPLEMENTATION_PLAN.md §7), so its data-level guarantees are asserted once here.
#
# Scope note: activity is the transition the ingest path owns. Fetch outcomes belong to
# Github::Enrichment::BatchRunner and DetailRunner, and leasing belongs to
# Github::Enrichment::BatchClaim and DetailClaim.
#
# The host group must provide `valid_attributes`.
RSpec.shared_examples "an enrichable entity" do
  let(:candidate_index_name) do
    "index_#{described_class.table_name}_on_enrichment_candidates"
  end

  let(:refresh_index_name) do
    "index_#{described_class.table_name}_on_enrichment_refresh"
  end

  let(:stage_fifo_index_name) do
    "index_#{described_class.table_name}_on_stage_fifo"
  end

  describe "enrichment status column" do
    it "starts pending so a newly observed entity is enrichment-eligible" do
      expect(described_class.create!(valid_attributes).enrichment_status).to eq("pending")
    end

    it "accepts every status the plan documents" do
      Enrichable::ENRICHMENT_STATUSES.each_with_index do |status, index|
        record = described_class.create!(
          valid_attributes.merge(github_id: 90_000 + index, enrichment_status: status)
        )
        expect(record.reload.enrichment_status).to eq(status)
      end
    end

    it "rejects an undocumented status at the database level" do
      record = described_class.create!(valid_attributes)

      expect_violation(ActiveRecord::CheckViolation) do
        described_class.where(id: record.id).update_all(enrichment_status: "invented")
      end
    end

    it "rejects the removed budget-skip status at both the model and database levels" do
      record = described_class.create!(valid_attributes)

      expect(record.update(enrichment_status: "skipped_budget")).to be(false)
      expect(record.errors[:enrichment_status]).to be_present

      expect_violation(ActiveRecord::CheckViolation) do
        described_class.where(id: record.id).update_all(enrichment_status: "skipped_budget")
      end
    end

    it "rejects a negative attempt count at the database level" do
      record = described_class.create!(valid_attributes)

      expect_violation(ActiveRecord::CheckViolation) do
        described_class.where(id: record.id).update_all(enrichment_attempts: -1)
      end
    end
  end

  # The staged pipeline's resting positions (§7, Appendix F). enrichment_status stays the
  # business outcome; the stage is where the row currently sits between the batch and
  # detail lanes, and the CHECK constraint is what keeps a torn write from inventing an
  # eighth position no claim would ever select.
  describe "enrichment stage column" do
    it "starts at batch_pending, the staged pipeline's entry position" do
      expect(described_class.create!(valid_attributes).enrichment_stage).to eq("batch_pending")
    end

    it "accepts every resting stage the plan documents" do
      Enrichable::ENRICHMENT_STAGES.each_with_index do |stage, index|
        record = described_class.create!(
          valid_attributes.merge(github_id: 93_000 + index, enrichment_stage: stage)
        )
        expect(record.reload.enrichment_stage).to eq(stage)
      end
    end

    it "rejects an undocumented stage at the database level" do
      record = described_class.create!(valid_attributes)

      expect_violation(ActiveRecord::CheckViolation) do
        described_class.where(id: record.id).update_all(enrichment_stage: "invented")
      end
    end

    # Both claims select FIFO *within* a stage set — batch by created_at, id over the
    # backlog stages — so the leading stage column is what lets one index answer either
    # claim's ordered scan without touching the other's rows.
    it "is backed by the stage-FIFO index the claims select through" do
      index = described_class.connection.indexes(described_class.table_name)
                             .find { |i| i.name == stage_fifo_index_name }

      expect(index).not_to be_nil
      expect(index.columns).to eq(%w[enrichment_stage created_at id])
    end
  end

  describe ".enrichment_candidates" do
    it "returns only pending and retryable_failure rows" do
      records = Enrichable::ENRICHMENT_STATUSES.each_with_index.to_h do |status, index|
        [ status, described_class.create!(
          valid_attributes.merge(github_id: 91_000 + index, enrichment_status: status)
        ) ]
      end

      expect(described_class.enrichment_candidates.map(&:id))
        .to contain_exactly(records["pending"].id, records["retryable_failure"].id)
    end

    it "is backed by a partial index over the reconciler's ordering columns" do
      index = described_class.connection.indexes(described_class.table_name)
                             .find { |i| i.name == candidate_index_name }

      expect(index).not_to be_nil
      expect(index.columns).to eq(%w[created_at id])

      # Assert semantically, not textually: PostgreSQL rewrites `IN (...)` into
      # `= ANY (ARRAY[...])`, so the stored predicate never matches the migration's
      # source form. Driving both lists off the constants keeps this honest if the
      # candidate set ever changes.
      Enrichable::CANDIDATE_STATUSES.each do |status|
        expect(index.where).to include(status)
      end

      (Enrichable::ENRICHMENT_STATUSES - Enrichable::CANDIDATE_STATUSES).each do |status|
        expect(index.where).not_to include(status)
      end
    end

    # §10's second pool. `complete` is excluded from the candidate index by its own
    # predicate, so without this one the TTL-stale refresh query has no index at all and
    # seq-scans a table dominated by pending rows.
    it "has a second partial index for the TTL-stale refresh pool, which the candidate one excludes" do
      index = described_class.connection.indexes(described_class.table_name)
                             .find { |i| i.name == refresh_index_name }

      expect(index).not_to be_nil
      # fetched_at leads because it carries both the range predicate and the ORDER BY, so
      # the scan is already ordered and stops at the first match.
      expect(index.columns).to eq(%w[fetched_at next_retry_at])
      expect(index.where).to include("complete")

      (Enrichable::ENRICHMENT_STATUSES - [ "complete" ]).each do |status|
        expect(index.where).not_to include(status)
      end
    end
  end

  describe ".touch_activity!" do
    let!(:record) { described_class.create!(valid_attributes) }

    it "records all three activity timestamps on a first observation" do
      described_class.touch_activity!(
        github_id: record.github_id,
        seen_at: frozen_time,
        event_occurred_at: frozen_time - 60
      )

      record.reload
      expect(record.first_seen_at).to eq(frozen_time)
      expect(record.last_seen_at).to eq(frozen_time)
      expect(record.latest_event_at).to eq(frozen_time - 60)
    end

    it "advances the timestamps for a newer observation" do
      described_class.touch_activity!(github_id: record.github_id,
                                     seen_at: frozen_time,
                                     event_occurred_at: frozen_time)
      described_class.touch_activity!(github_id: record.github_id,
                                      seen_at: frozen_time + 300,
                                      event_occurred_at: frozen_time + 200)

      record.reload
      expect(record.first_seen_at).to eq(frozen_time)
      expect(record.last_seen_at).to eq(frozen_time + 300)
      expect(record.latest_event_at).to eq(frozen_time + 200)
    end

    # A delayed event carries an older created_at (documented 30s-6h latency), and
    # sources commit independently. Activity timestamps must remain monotone even though
    # durable FIFO selection is based on the entity row's immutable created_at.
    it "never regresses an activity timestamp for an older observation" do
      described_class.touch_activity!(github_id: record.github_id,
                                      seen_at: frozen_time + 300,
                                      event_occurred_at: frozen_time + 200)
      described_class.touch_activity!(github_id: record.github_id,
                                      seen_at: frozen_time + 100,
                                      event_occurred_at: frozen_time + 50)

      record.reload
      expect(record.last_seen_at).to eq(frozen_time + 300)
      expect(record.latest_event_at).to eq(frozen_time + 200)
    end

    it "keeps the earliest observation in first_seen_at" do
      described_class.touch_activity!(github_id: record.github_id,
                                      seen_at: frozen_time + 300,
                                      event_occurred_at: frozen_time + 300)
      described_class.touch_activity!(github_id: record.github_id,
                                      seen_at: frozen_time,
                                      event_occurred_at: frozen_time)

      expect(record.reload.first_seen_at).to eq(frozen_time)
    end
  end

  describe "the candidate-status invariant" do
    it "never leaves a candidate carrying a fetched document" do
      Enrichable::CANDIDATE_STATUSES.each_with_index do |status, index|
        described_class.create!(valid_attributes.merge(github_id: 92_000 + index,
                                                       enrichment_status: status))
      end

      expect(described_class.enrichment_candidates.where.not(fetched_at: nil)).to be_empty
      expect(described_class.enrichment_candidates.where.not(raw_payload: nil)).to be_empty
    end
  end
end
