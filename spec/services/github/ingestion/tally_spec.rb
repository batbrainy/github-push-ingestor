require "rails_helper"

RSpec.describe Github::Ingestion::Tally do
  subject(:empty) { described_class.empty }

  # Page 1 of the corpus, recorded envelope by envelope: three well-formed pushes, one
  # WatchEvent, two malformed pushes, one typeless envelope, one more well-formed push.
  # Every expected count in the integration specs derives from this sequence.
  def page_one_tally
    described_class.empty
      .record_page(events_received: 8)
      .record(result: :created, push_type: true)
      .record(result: :created, push_type: true)
      .record(result: :created, push_type: true)
      .record(result: :ignored, push_type: false)
      .record(result: :quarantined, push_type: true)
      .record(result: :quarantined, push_type: true)
      .record(result: :quarantined, push_type: false)
      .record(result: :created, push_type: true)
  end

  describe ".empty" do
    it "starts every counter at zero" do
      expect(empty.to_h.values).to all(eq(0))
    end
  end

  describe "#record_page" do
    it "counts one page and the envelopes it carried" do
      tally = empty.record_page(events_received: 8)

      expect(tally.pages_fetched).to eq(1)
      expect(tally.events_received).to eq(8)
    end

    it "accumulates across pages, which is what the page loop threads through the writer" do
      tally = empty.record_page(events_received: 8).record_page(events_received: 3)

      expect(tally.pages_fetched).to eq(2)
      expect(tally.events_received).to eq(11)
    end

    it "counts an empty page as a page" do
      expect(empty.record_page(events_received: 0).pages_fetched).to eq(1)
    end
  end

  describe "#record" do
    it "leaves the receiver untouched, so a counter cannot be bumped from two places" do
      empty.record(result: :created, push_type: true)

      expect(empty.events_created).to eq(0)
    end

    it "maps every result onto exactly one column" do
      described_class::RESULTS.each do |result, column|
        tally = empty.record(result: result, push_type: false)

        expect(tally.public_send(column)).to eq(1)
        expect(tally.to_h.values.sum).to eq(1)
      end
    end

    # §8 step 4 filters PushEvent entries, so an envelope GitHub typed as a push is a push
    # event seen even when it then quarantined.
    it "counts a quarantined PushEvent as a push event seen" do
      tally = empty.record(result: :quarantined, push_type: true)

      expect(tally.push_events_seen).to eq(1)
      expect(tally.events_quarantined).to eq(1)
    end

    it "does not count an envelope with no usable type as a push event seen" do
      tally = empty.record(result: :quarantined, push_type: false)

      expect(tally.push_events_seen).to eq(0)
    end

    it "refuses an unknown result rather than dropping the envelope silently" do
      expect { empty.record(result: :maybe, push_type: false) }
        .to raise_error(ArgumentError, /unknown result :maybe/)
    end
  end

  describe "the counter identities" do
    let(:tally) { page_one_tally }

    # Page 1's three quarantines split two push-typed (ids …005 and …006) and one with no
    # usable type (…007). The tally does not store that split — which is exactly why
    # events_ignored is not derivable from the persisted columns — so it is stated here.
    let(:push_quarantines) { 2 }
    let(:envelope_quarantines) { 1 }

    it "accounts for every envelope received" do
      expect(tally.events_received)
        .to eq(tally.push_events_seen + tally.events_ignored + envelope_quarantines)
    end

    it "accounts for every push event seen" do
      expect(tally.push_events_seen)
        .to eq(tally.events_created + tally.duplicates_skipped + push_quarantines + tally.events_failed)
    end

    it "reproduces page 1's expected counts" do
      expect(tally.to_h).to eq(
        pages_fetched: 1, events_received: 8, push_events_seen: 6, events_created: 4,
        duplicates_skipped: 0, events_quarantined: 3, events_ignored: 1, events_failed: 0
      )
    end
  end

  describe "#persistable_attributes" do
    it "carries exactly the seven columns §7 lists on ingestion_runs" do
      expect(page_one_tally.persistable_attributes.keys).to eq(IngestionRun::COUNTERS)
    end

    # There is no events_ignored column, and it is not derivable from the stored counters:
    # an envelope with no usable type is quarantined rather than ignored, so
    # events_received - push_events_seen counts both.
    it "omits events_ignored, which has no column" do
      expect(page_one_tally.persistable_attributes).not_to have_key(:events_ignored)
      expect(page_one_tally.to_log).to include(events_ignored: 1)
    end

    it "produces attributes an IngestionRun accepts" do
      run = IngestionRun.new(event_source: create_event_source, started_at: frozen_time,
                             status: "running", **page_one_tally.persistable_attributes)

      expect(run).to be_valid
    end
  end

  describe "#to_s" do
    let(:rendered) { page_one_tally.to_s.lines.map(&:chomp) }

    # §9: "On a live run it prints the end-of-run summary: pages fetched, events seen,
    # push events created, duplicates skipped, events quarantined, budget remaining."
    it "prints the counters §9 names" do
      expect(rendered).to include(
        a_string_starting_with("Pages fetched:"),
        a_string_starting_with("Events seen:"),
        a_string_starting_with("Push events created:"),
        a_string_starting_with("Duplicates skipped:"),
        a_string_starting_with("Events quarantined:")
      )
    end

    # Budget remaining lives on the state summary, which prints immediately after. One
    # number, not two that could disagree.
    it "leaves budget remaining to the state summary" do
      expect(page_one_tally.to_s).not_to include("Budget remaining")
    end

    it "aligns every value on the shared report column" do
      column = Github::Ingestion::Report::LABEL_WIDTH

      rendered.each do |line|
        expect(line[column - 1]).to eq(" "), "expected padding before the value in #{line.inspect}"
        expect(line[column]).not_to eq(" "), "expected the value to start at column #{column}"
      end
    end

    it "delimits a large count" do
      tally = described_class.empty.record_page(events_received: 1_284)

      expect(tally.to_s).to include("1,284")
    end
  end
end
