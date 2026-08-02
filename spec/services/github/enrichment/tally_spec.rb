require "rails_helper"

RSpec.describe Github::Enrichment::Tally do
  def batch_result(status:, requested: 0, valid: 0, fallback: 0)
    Github::Enrichment::BatchRunner::Result.new(
      status: status, entity_type: :actor, batch_id: 41, requested_count: requested,
      returned_count: valid, valid_count: valid, fallback_count: fallback,
      deferral_reason: nil
    )
  end

  def detail_result(status:)
    Github::Enrichment::DetailRunner::Result.new(
      status: status, entity_type: :actor, github_id: 583_231, batch_id: 42, reason: nil
    )
  end

  it "starts at zero on every counter" do
    expect(described_class.empty.to_h.values).to all(eq(0))
  end

  describe "#record_batch" do
    it "counts a completed batch with its item outcomes" do
      tally = described_class.empty
                             .record_batch(batch_result(status: "completed", requested: 10,
                                                        valid: 8, fallback: 2))

      expect(tally).to have_attributes(requests: 1, batches_completed: 1, batches_failed: 0,
                                       items_requested: 10, items_valid: 8, fallbacks_admitted: 2)
    end

    # A failed batch still spent the request and still asked for its items — that is what
    # the fill-ratio arithmetic downstream needs — but applied nothing.
    it "counts a failed batch's request and items without inventing applied ones" do
      tally = described_class.empty.record_batch(batch_result(status: "failed", requested: 10))

      expect(tally).to have_attributes(requests: 1, batches_failed: 1, batches_completed: 0,
                                       items_requested: 10, items_valid: 0, fallbacks_admitted: 0)
    end

    it "counts a deferred batch as a spent request that decided nothing" do
      tally = described_class.empty.record_batch(batch_result(status: "deferred"))

      expect(tally).to have_attributes(requests: 1, deferred: 1, batches_completed: 0)
    end

    # An idle claim locked nothing and asked GitHub for nothing — counting it as a request
    # would make --limit stop short of the requests the operator asked for.
    it "counts an idle claim without counting a request" do
      tally = described_class.empty.record_batch(batch_result(status: "idle"))

      expect(tally).to have_attributes(requests: 0, idle: 1)
    end

    it "refuses an unknown status rather than dropping it" do
      expect { described_class.empty.record_batch(batch_result(status: "invented")) }
        .to raise_error(ArgumentError, /invented/)
    end
  end

  describe "#record_detail" do
    # Every decided detail outcome is one spent request under its own name; a terminal 404
    # is a decision, not a failure, which is why it has its own counter and exit-code rule.
    it "counts each decided outcome under its own name" do
      tally = described_class.empty
                             .record_detail(detail_result(status: "completed"))
                             .record_detail(detail_result(status: "terminal"))
                             .record_detail(detail_result(status: "retry_scheduled"))

      expect(tally).to have_attributes(requests: 3, details_completed: 1, details_terminal: 1,
                                       details_retrying: 1)
    end

    it "counts a deferral and a lost lease as spent requests that decided nothing" do
      tally = described_class.empty
                             .record_detail(detail_result(status: "deferred"))
                             .record_detail(detail_result(status: "lease_lost"))

      expect(tally).to have_attributes(requests: 2, deferred: 1, lease_lost: 1,
                                       details_completed: 0)
    end

    it "counts an idle claim without counting a request" do
      tally = described_class.empty.record_detail(detail_result(status: "idle"))

      expect(tally).to have_attributes(requests: 0, idle: 1)
    end

    it "refuses an unknown status rather than dropping it" do
      expect { described_class.empty.record_detail(detail_result(status: "invented")) }
        .to raise_error(ArgumentError, /invented/)
    end
  end

  # Immutable, like Github::Ingestion::Tally: a partially accumulated count can never be
  # observed, and a caller cannot hold a reference that later changes underneath it.
  it "returns a new value rather than mutating, so no caller sees a partial count" do
    empty = described_class.empty

    expect { empty.record_batch(batch_result(status: "completed")) }
      .not_to change { empty.requests }.from(0)
  end

  it "accumulates both lanes into one request count, which is what --limit bounds" do
    tally = described_class.empty
                           .record_batch(batch_result(status: "completed", requested: 10, valid: 10))
                           .record_detail(detail_result(status: "completed"))

    expect(tally.requests).to eq(2)
  end

  describe "#to_s" do
    it "prints the staged-pipeline counters an operator reads after a run" do
      rendered = described_class.empty
                                .record_batch(batch_result(status: "completed", requested: 10,
                                                           valid: 8, fallback: 2))
                                .record_detail(detail_result(status: "terminal"))
                                .to_s

      expect(rendered).to include(
        "Requests attempted", "Search batches completed", "Batch items requested",
        "Batch items applied", "Fallbacks admitted", "Detail completions",
        "Detail terminal outcomes", "Requests deferred", "Claims with nothing eligible"
      )
    end

    it "carries no discarded-work counter, because deferral is not discard" do
      expect(described_class.empty.to_s).not_to include("skipped")
    end
  end
end
