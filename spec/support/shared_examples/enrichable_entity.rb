# github_actors and github_repositories carry an identical enrichment state machine
# (IMPLEMENTATION_PLAN.md §7), so its data-level guarantees are asserted once here.
#
# Scope note: this covers the two transitions the *ingest* path owns — the activity
# effect and §7 merge rule 3's reactivation. Every other transition is a fetch outcome
# and belongs to Github::Enrichment::EntityState, Github::Enrichment::AgeOut, and
# Github::Enrichment::Claim, each with its own spec.
#
# The host group must provide `valid_attributes`.
RSpec.shared_examples "an enrichable entity" do
  let(:candidate_index_name) do
    "index_#{described_class.table_name}_on_enrichment_candidates"
  end

  let(:refresh_index_name) do
    "index_#{described_class.table_name}_on_enrichment_refresh"
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

    # The two halves of §7 merge rule 3 are separate statements, and this is the one that
    # keeps them honest: an activity update is not a state transition. Reactivation is
    # .reactivate_skipped!'s single job, and separating them is what lets that method's row
    # count be exactly the number §11 asks to see logged.
    it "does not change enrichment status, which reactivation is separately responsible for" do
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

  # §7's reactivation rule: "skipped_budget is terminal for the entity's current
  # eligibility window, not forever." Rule 4 — a duplicate replay can never reactivate — is
  # held by the *call site*, so it is asserted in page_writer_spec.rb rather than here.
  describe ".reactivate_skipped!" do
    let!(:record) { described_class.create!(valid_attributes) }

    def skip!(**overrides)
      described_class.where(id: record.id)
                     .update_all({ enrichment_status: "skipped_budget", skipped_at: frozen_time }.merge(overrides))
    end

    it "returns a skipped entity to pending, because a distinct persisted event proves new activity" do
      skip!

      expect(described_class.reactivate_skipped!(github_id: record.github_id, now: frozen_time + 600)).to eq(1)
      expect(record.reload).to have_attributes(enrichment_status: "pending", skipped_at: nil)
    end

    # §7 line 572: "An entity in the complete state is not reset to pending by a duplicate."
    it "leaves every other status alone, so no enriched or terminally failed row is disturbed" do
      (Enrichable::ENRICHMENT_STATUSES - [ "skipped_budget" ]).each do |status|
        described_class.where(id: record.id).update_all(enrichment_status: status)

        expect(described_class.reactivate_skipped!(github_id: record.github_id, now: frozen_time)).to eq(0)
        expect(record.reload.enrichment_status).to eq(status)
      end
    end

    # enrichment_attempts and last_error are records of *fetches*, and an inbound envelope
    # is not a fetch. next_retry_at is left because Github::Enrichment::AgeOut never skips a
    # row whose retry is in the future, so a reactivated row is provably due immediately.
    it "keeps the failure history a reactivated entity carries, because no fetch just happened" do
      skip!(enrichment_attempts: 3, last_error: "boom", next_retry_at: frozen_time - 60)

      described_class.reactivate_skipped!(github_id: record.github_id, now: frozen_time)

      expect(record.reload).to have_attributes(enrichment_attempts: 3, last_error: "boom",
                                               next_retry_at: frozen_time - 60)
    end

    # Two representations of "skipped" is two things that can disagree, which is the drift
    # EventSource's own comment names.
    it "never leaves a skipped instant on a row that is no longer skipped" do
      skip!
      described_class.reactivate_skipped!(github_id: record.github_id, now: frozen_time)

      expect(described_class.where.not(enrichment_status: "skipped_budget").where.not(skipped_at: nil))
        .to be_empty
    end
  end

  # The derived invariant Enrichable#reactivate_skipped! relies on to need no
  # "missing or stale" sub-predicate: skipped_budget implies missing enrichment, because
  # AgeOut only ever skips rows in CANDIDATE_STATUSES and no row in those two statuses has
  # ever completed a fetch.
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
