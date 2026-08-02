require "rails_helper"

RSpec.describe Github::Enrichment::BatchQuality do
  let(:now) { frozen_time }

  def capture(configuration: Github.configuration)
    described_class.capture(now: now, configuration: configuration)
  end

  # correlation_id is passed explicitly because the model validates its presence while
  # the column's gen_random_uuid() default is database-side, so a bare create! never
  # sees a value to validate.
  def create_batch(request_kind: "search", entity_kind: "actor", status: "succeeded",
                   started_at: now - 60, **overrides)
    EnrichmentBatch.create!(
      request_kind: request_kind, entity_kind: entity_kind, status: status,
      started_at: started_at, correlation_id: SecureRandom.uuid, **overrides
    )
  end

  describe "the four groups" do
    # An empty table was read and held nothing — that is a counted zero, not an absent
    # key, so all four request-kind x entity-kind groups are always published.
    it "publishes every group with counted zeros on an empty table" do
      payload = capture.payload

      expect(payload.keys).to eq(%i[window_seconds window_start search detail])
      %i[search detail].each do |kind|
        %i[actors repositories].each do |entity|
          expect(payload.dig(kind, entity)).to eq(described_class::EMPTY_GROUP.to_h)
        end
      end
      expect(payload.dig(:search, :actors, :fill_ratio)).to be_nil
    end

    it "routes each batch to its own request-kind x entity-kind group" do
      create_batch(request_kind: "search", entity_kind: "actor")
      create_batch(request_kind: "search", entity_kind: "repository")
      create_batch(request_kind: "detail", entity_kind: "actor")
      create_batch(request_kind: "detail", entity_kind: "actor")

      payload = capture.payload

      expect(payload.dig(:search, :actors, :attempts)).to eq(1)
      expect(payload.dig(:search, :repositories, :attempts)).to eq(1)
      expect(payload.dig(:detail, :actors, :attempts)).to eq(2)
      expect(payload.dig(:detail, :repositories, :attempts)).to eq(0)
    end
  end

  describe "the status tally" do
    it "counts each of the five batch outcomes separately" do
      EnrichmentBatch::STATUSES.each { |status| create_batch(status: status) }

      expect(capture.payload.dig(:search, :actors)).to include(
        attempts: 5, in_flight: 1, succeeded: 1, failed: 1, deferred: 1, stale_lease: 1
      )
    end
  end

  describe "the item sums and fill ratio" do
    it "sums the item counters across the group's batches" do
      create_batch(requested_count: 10, returned_count: 9, valid_count: 8,
                   missing_count: 1, invalid_count: 1)
      create_batch(requested_count: 10, returned_count: 7, valid_count: 6,
                   missing_count: 3, invalid_count: 1)

      expect(capture.payload.dig(:search, :actors)).to include(
        requested_items: 20, returned_items: 16, valid_items: 14,
        missing_items: 4, invalid_items: 2, fill_ratio: 0.8
      )
    end

    it "rounds the fill ratio to three decimals" do
      create_batch(requested_count: 3, returned_count: 1)

      expect(capture.payload.dig(:search, :actors, :fill_ratio)).to eq(0.333)
    end

    # A ratio with a zero denominator is undefined, never 0.0 — §16's fabricated-zero
    # rule. The denominator is published beside it, so null is self-explanatory.
    it "reports a null fill ratio when nothing was requested" do
      create_batch(status: "deferred", requested_count: 0, returned_count: 0)

      expect(capture.payload.dig(:search, :actors))
        .to include(attempts: 1, requested_items: 0, fill_ratio: nil)
    end
  end

  describe "the incomplete_results count" do
    # GitHub's Search envelope flag: recorded per batch, counted only when it was
    # actually true — an absent flag (detail batches never carry one) is not a false.
    it "counts only batches whose envelope said incomplete_results true" do
      create_batch(incomplete_results: true)
      create_batch(incomplete_results: false)
      create_batch(incomplete_results: nil)

      expect(capture.payload.dig(:search, :actors, :incomplete_results_count)).to eq(1)
    end
  end

  describe "the trailing window" do
    it "filters on started_at with an inclusive floor" do
      create_batch(started_at: now - 3600)
      create_batch(started_at: now - 3601)

      quality = capture

      expect(quality.payload.dig(:search, :actors, :attempts)).to eq(1)
      expect(quality.window_start).to eq(now - 3600)
    end

    it "reads the window from the configuration it was given" do
      create_batch(started_at: now - 700)
      configuration = configuration_with(ENRICHMENT_METRICS_WINDOW_SECONDS: "600")

      expect(capture(configuration: configuration).payload)
        .to include(window_seconds: 600, window_start: (now - 600).utc.iso8601)
      expect(capture(configuration: configuration).payload.dig(:search, :actors, :attempts)).to eq(0)
    end
  end

  describe "consistency" do
    # Batches commit while /status reads. One grouped statement means the counts of one
    # group can never describe a different instant than another group's.
    it "captures every group in one grouped statement, writing nothing" do
      create_batch
      create_batch(request_kind: "detail", entity_kind: "repository")

      statements = capture_sql { capture }
      selects = statements.grep(/\A\s*SELECT/i)

      expect(selects.length).to eq(1)
      expect(selects.first).to include('FROM "enrichment_batches"', "GROUP BY")
      expect(statements.grep(SqlHelpers::WRITE)).to be_empty
    end
  end
end
