# github_actors and github_repositories carry an identical enrichment state machine
# (IMPLEMENTATION_PLAN.md §7), so its data-level guarantees are asserted once here.
#
# Scope note: PR 3 owns the state *column* and the activity *effect*. Enrichment
# transitions — TTL staleness, budget skips, and skipped_budget reactivation — are
# PR 7, so nothing here asserts a status change.
#
# The host group must provide `valid_attributes`.
RSpec.shared_examples "an enrichable entity" do
  let(:candidate_index_name) do
    "index_#{described_class.table_name}_on_enrichment_candidates"
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

    it "rejects a negative attempt count at the database level" do
      record = described_class.create!(valid_attributes)

      expect_violation(ActiveRecord::CheckViolation) do
        described_class.where(id: record.id).update_all(enrichment_attempts: -1)
      end
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
      expect(index.columns).to eq(%w[next_retry_at last_seen_at])

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
    # sources commit independently. An older observation must never move newest-first
    # enrichment ordering backwards.
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

    it "does not change enrichment status, because transitions are PR 7's scope" do
      described_class.where(id: record.id)
                     .update_all(enrichment_status: "skipped_budget", skipped_at: frozen_time)

      described_class.touch_activity!(github_id: record.github_id,
                                      seen_at: frozen_time + 600,
                                      event_occurred_at: frozen_time + 600)

      record.reload
      expect(record.enrichment_status).to eq("skipped_budget")
      expect(record.skipped_at).to eq(frozen_time)
    end
  end
end
