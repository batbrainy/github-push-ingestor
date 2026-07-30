require "rails_helper"

RSpec.describe Github::Enrichment::Tally do
  def result(status:, aged_out: 0)
    Github::EnrichmentRunner::Result.new(status: status, aged_out: aged_out)
  end

  it "starts at zero on every counter" do
    expect(described_class.empty.to_h.values).to all(eq(0))
  end

  it "counts each outcome under its own name" do
    tally = described_class.empty
                           .record(result(status: "enriched"))
                           .record(result(status: "failed"))
                           .record(result(status: "deferred"))

    expect(tally).to have_attributes(cycles: 3, enriched: 1, failed: 1, deferred: 1, idle: 0)
  end

  it "accumulates the candidates each cycle aged out" do
    tally = described_class.empty
                           .record(result(status: "idle", aged_out: 4))
                           .record(result(status: "idle", aged_out: 2))

    expect(tally.aged_out).to eq(6)
  end

  # Immutable, like Github::Ingestion::Tally: a partially accumulated count can never be
  # observed, and a caller cannot hold a reference that later changes underneath it.
  it "returns a new value rather than mutating, so no caller sees a partial count" do
    empty = described_class.empty

    expect { empty.record(result(status: "enriched")) }.not_to change { empty.cycles }.from(0)
  end

  # Keyed by the runner's own statuses, so a new outcome cannot be silently uncounted.
  it "covers every status the runner can return" do
    expect(described_class::COUNTERS.keys).to match_array(Github::EnrichmentRunner::Result::STATUSES)
  end

  it "refuses an unknown status rather than dropping it" do
    expect { described_class.empty.record(Struct.new(:status, :aged_out).new("invented", 0)) }
      .to raise_error(ArgumentError, /invented/)
  end

  it "prints the counters an operator reads the sampling rate from" do
    rendered = described_class.empty.record(result(status: "enriched", aged_out: 1_234)).to_s

    expect(rendered).to include("Entities enriched", "Candidates skipped (budget)", "1,234")
  end
end
