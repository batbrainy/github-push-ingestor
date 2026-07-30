require "rails_helper"

RSpec.describe Github::Events::QuarantineReasons do
  describe "the vocabulary" do
    it "derives CODES from TAXONOMY, so a code cannot exist without naming its plan row" do
      expect(described_class::CODES).to eq(described_class::TAXONOMY.keys)
    end

    it "maps every code to one of §7's three quarantining rows" do
      expect(described_class::TAXONOMY.values.uniq).to match_array(described_class::ROWS.keys)
    end

    it "exercises every row, so the granularity refines the plan rather than drifting from it" do
      described_class::ROWS.each_key do |row|
        expect(described_class::TAXONOMY.values).to include(row)
      end
    end

    it "keeps the codes and the precedence order in sync" do
      expect(described_class::PRECEDENCE).to match_array(described_class::CODES)
    end

    it "freezes the vocabulary, because error_code is never revised once written" do
      expect(described_class::CODES).to be_frozen
      expect(described_class::TAXONOMY).to be_frozen
      expect(described_class::PRECEDENCE).to be_frozen
    end
  end

  describe ".primary" do
    # Structure before identity: you cannot ask a null element whether its head is a
    # valid object name.
    it "prefers a structural failure over an identity failure" do
      codes = [ described_class::MISSING_EVENT_ID, described_class::INVALID_ENVELOPE ]

      expect(described_class.primary(codes)).to eq(described_class::INVALID_ENVELOPE)
    end

    # Envelope identity before payload: the quarantine row is indexed by
    # github_event_id and carries event_type, and both come from the envelope.
    it "prefers an envelope identity failure over a payload failure" do
      codes = [ described_class::MISSING_REQUIRED_FIELD, described_class::MISSING_EVENT_TYPE ]

      expect(described_class.primary(codes)).to eq(described_class::MISSING_EVENT_TYPE)
    end

    it "prefers absence over unusable shape, because the two have different remedies" do
      codes = [ described_class::INVALID_FIELD_FORMAT, described_class::MISSING_REQUIRED_FIELD ]

      expect(described_class.primary(codes)).to eq(described_class::MISSING_REQUIRED_FIELD)
    end

    # Shape before integrity. A String "1296269" is != the Integer 1296269, so
    # integrity-first would report a mismatch that does not exist.
    it "prefers a shape failure over an integrity failure" do
      codes = [ described_class::REPOSITORY_ID_MISMATCH, described_class::INVALID_FIELD_FORMAT ]

      expect(described_class.primary(codes)).to eq(described_class::INVALID_FIELD_FORMAT)
    end

    it "leaves range last, since it can only be judged on a value that parsed" do
      expect(described_class.primary(described_class::CODES.shuffle))
        .to eq(described_class::INVALID_ENVELOPE)
      expect(described_class::PRECEDENCE.last).to eq(described_class::IDENTIFIER_OUT_OF_RANGE)
    end

    it "returns nil for an envelope that violated nothing" do
      expect(described_class.primary([])).to be_nil
    end

    it "refuses a code outside the taxonomy rather than ordering it arbitrarily" do
      expect { described_class.primary([ "improvised" ]) }
        .to raise_error(ArgumentError, /not a member of the quarantine taxonomy/)
    end
  end

  describe ".row" do
    it "names the plan row a code implements" do
      expect(described_class.row(described_class::REPOSITORY_ID_MISMATCH)).to eq(:integrity_failure)
    end

    it "raises for an unknown code" do
      expect { described_class.row("improvised") }.to raise_error(KeyError)
    end
  end
end
