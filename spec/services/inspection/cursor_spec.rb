require "rails_helper"

RSpec.describe Inspection::Cursor do
  let(:occurred_at) { Time.utc(2026, 7, 29, 12, 0, 0, 123_456) }

  describe "the round trip" do
    it "returns the position it encoded" do
      decoded = described_class.decode(described_class.new(occurred_at: occurred_at, id: 42).encode)

      expect(decoded).to eq(described_class.new(occurred_at: occurred_at, id: 42))
    end

    # push_events.occurred_at is timestamp(6), and a whole-second cursor would be ambiguous
    # inside a single second — which is exactly the window one poll writes an entire page of
    # events into, and therefore exactly where a page boundary is most likely to fall.
    it "keeps microseconds, because a whole second holds a whole page" do
      decoded = described_class.decode(described_class.new(occurred_at: occurred_at, id: 1).encode)

      expect(decoded.occurred_at.usec).to eq(123_456)
    end

    it "is URL-safe and unpadded, so it survives a query string untouched" do
      encoded = described_class.new(occurred_at: occurred_at, id: 42).encode

      expect(encoded).to match(/\A[A-Za-z0-9\-_]+\z/)
    end

    it "reads a position straight off a record" do
      actor = create_actor(github_id: 1)
      repository = create_repository(github_id: 2)
      event = create_push_event(actor: actor, repository: repository)

      expect(described_class.from(event))
        .to eq(described_class.new(occurred_at: event.occurred_at, id: event.id))
    end
  end

  # nil rather than a fallback to the first page. A paging client that corrupts its cursor
  # and silently gets page one back would loop forever without ever seeing an error; the
  # caller turns this nil into a 400.
  describe "input it cannot read" do
    it "refuses anything that is not a cursor it issued" do
      [ "not-base64!", Base64.urlsafe_encode64("junk"),
        Base64.urlsafe_encode64("2026-07-29T12:00:00Z|abc"),
        Base64.urlsafe_encode64("|42"),
        Base64.urlsafe_encode64("not-a-time|42") ].each do |value|
        expect(described_class.decode(value)).to be_nil, "expected #{value.inspect} refused"
      end
    end

    it "treats blank as absent rather than as corrupt" do
      expect(described_class.decode(nil)).to be_nil
      expect(described_class.decode("")).to be_nil
    end

    # Well-formed but unrepresentable. Both halves reach the seek predicate as raw binds,
    # where PostgreSQL raises rather than casts — PG::NumericValueOutOfRange one past
    # BIGINT_MAX, and PG::DatetimeFieldOverflow one year past MAX_TIMESTAMP_YEAR — so
    # without this a forged cursor is a 500 on input the client fully controls. Ruby is no
    # help: Time.iso8601 parses a year in the hundreds of millions without complaint.
    it "refuses a position the database could not compare against" do
      [ "2026-07-29T12:00:00Z|#{Inspection::BIGINT_MAX + 1}",
        "999999999-01-01T00:00:00Z|42",
        "#{Inspection::MAX_TIMESTAMP_YEAR + 1}-01-01T00:00:00Z|42" ].each do |forged|
        expect(described_class.decode(Base64.urlsafe_encode64(forged)))
          .to be_nil, "expected #{forged.inspect} refused"
      end
    end

    # The bounds are inclusive: the guard must refuse what the database cannot hold and
    # nothing else.
    it "accepts the exact edge of what the database can hold" do
      edge = "#{Time.utc(Inspection::MAX_TIMESTAMP_YEAR).iso8601(6)}|#{Inspection::BIGINT_MAX}"

      expect(described_class.decode(Base64.urlsafe_encode64(edge)))
        .to have_attributes(id: Inspection::BIGINT_MAX,
                            occurred_at: Time.utc(Inspection::MAX_TIMESTAMP_YEAR))
    end
  end
end
