require "rails_helper"

RSpec.describe Inspection::PushEventPage do
  let(:actor) { create_actor(github_id: 1001) }
  let(:repository) { create_repository(github_id: 2001) }

  # Explicit ids and explicit instants: the unique index on github_event_id is the arbiter,
  # and an implicit sequence would hide the ordering under test from the example reading it.
  # `prefix` is what lets one example build two series without colliding on that index.
  def series(count, occurred_at: frozen_time, prefix: 4, actor: self.actor,
             repository: self.repository)
    (1..count).map do |n|
      create_push_event(actor: actor, repository: repository,
                        github_event_id: "#{prefix}000000#{format("%04d", n)}",
                        occurred_at: occurred_at + n)
    end
  end

  def page(**params) = described_class.for(params)
  def ids(page) = page.records.map(&:id)

  describe "ordering" do
    it "returns the newest event first" do
      oldest, middle, newest = series(3)

      expect(ids(page)).to eq([ newest.id, middle.id, oldest.id ])
    end

    # occurred_at is not unique — one poll commits a whole page of events at once — so
    # without the id tiebreak the order inside a group is whatever the plan happens to
    # produce, and a page boundary falling inside that group loses or repeats rows.
    it "orders deterministically when occurred_at ties" do
      tied = 3.times.map do |n|
        create_push_event(actor: actor, repository: repository,
                          github_event_id: "5000000000#{n}", occurred_at: frozen_time)
      end

      first = page(limit: 1)
      second = page(limit: 1, cursor: first.next_cursor.encode)
      third = page(limit: 1, cursor: second.next_cursor.encode)

      expect(ids(first) + ids(second) + ids(third)).to eq(tied.map(&:id).sort.reverse)
    end

    it "answers identically to an identical request" do
      series(3)

      expect(ids(page)).to eq(ids(page))
    end
  end

  describe "keyset paging" do
    # The limit + 1 probe. Without it every list advertises a phantom empty next page, and
    # a client dutifully fetches it.
    it "offers no next page when the last row fits exactly" do
      series(3)

      expect(page(limit: 3).next_cursor).to be_nil
    end

    it "offers a next page when one more row exists" do
      series(4)
      first = page(limit: 3)

      expect(first.next_cursor).to be_present
      expect(ids(page(limit: 3, cursor: first.next_cursor.encode)).length).to eq(1)
    end

    it "walks the whole table without repeating or skipping a row" do
      all = series(5)
      walked = []
      cursor = nil

      loop do
        current = page(limit: 2, cursor: cursor&.encode)
        walked.concat(ids(current))
        cursor = current.next_cursor
        break if cursor.nil?
      end

      expect(walked).to eq(all.reverse.map(&:id))
      expect(walked.uniq).to eq(walked)
    end

    # The example that justifies keyset over offset. The poller writes continuously and this
    # list is newest-first, so under ?offset=N a row that landed between pages shifts
    # everything down: page 2 re-serves rows from page 1 and skips others.
    it "neither repeats nor skips a row when a new event lands between pages" do
      older = series(4)
      first = page(limit: 2)
      create_push_event(actor: actor, repository: repository,
                        github_event_id: "40000000099", occurred_at: frozen_time + 1.hour)

      second = page(limit: 2, cursor: first.next_cursor.encode)

      expect(ids(second)).not_to include(*ids(first))
      expect(ids(first) + ids(second)).to eq(older.reverse.map(&:id))
    end

    it "returns an empty page past the end rather than restarting" do
      series(2)
      last = page(limit: 2)
      beyond = page(limit: 2, cursor: Inspection::Cursor.from(last.records.last).encode)

      expect(beyond.records).to be_empty
      expect(beyond.next_cursor).to be_nil
    end

    it "returns nothing at all on an empty table" do
      expect(page).to have_attributes(records: [], next_cursor: nil, limit: 25)
    end
  end

  describe "filters" do
    it "narrows to one actor and to one repository" do
      other_actor = create_actor(github_id: 1002, login: "other")
      other_repository = create_repository(github_id: 2002, full_name: "other/repo")
      mine = series(1)
      series(1, prefix: 5, actor: other_actor, repository: other_repository)

      expect(ids(page(actor_id: actor.github_id))).to eq(mine.map(&:id))
      expect(ids(page(repository_id: other_repository.github_id)).length).to eq(1)
    end

    # A filter matching nothing is a true answer, not a missing resource.
    it "answers an empty page for an id nothing references" do
      series(2)

      expect(page(actor_id: 999_999).records).to be_empty
    end
  end

  describe "parameter validation" do
    it "defaults the limit, and treats blank as absent rather than as zero" do
      expect(page.limit).to eq(described_class::DEFAULT_LIMIT)
      expect(page(limit: "").limit).to eq(described_class::DEFAULT_LIMIT)
      expect(page(limit: "100").limit).to eq(100)
    end

    # Refused rather than clamped to MAX_LIMIT: a client that asked for 500 and received
    # 100 cannot tell whether it received everything, and §16 rules out that kind of
    # misleading answer. The ceiling is named so the correction takes one round trip.
    it "refuses an out-of-range limit instead of silently clamping it" do
      expect { page(limit: "99999") }
        .to raise_error(Inspection::Errors::InvalidParameter, /limit must be an integer from 1 to 100/)
      expect { page(limit: "0") }.to raise_error(Inspection::Errors::InvalidParameter)
      expect { page(limit: "-1") }.to raise_error(Inspection::Errors::InvalidParameter)
    end

    it "refuses anything that is not a decimal integer" do
      [ "abc", "1.5", "1e2", "0x10", "1_0", " 5", "+5" ].each do |value|
        expect { page(limit: value) }
          .to raise_error(Inspection::Errors::InvalidParameter),
              "expected limit=#{value.inspect} refused"
      end
    end

    # The reason the regex is \A\d+\z rather than Kernel#Integer. Integer("010") is 8 —
    # a leading zero silently switches the base, so "?limit=010" would return eight rows to
    # a client that asked for ten. Read as decimal it means what it reads as.
    it "reads a leading zero as decimal, not as octal" do
      expect(page(limit: "010").limit).to eq(10)
    end

    it "refuses a github id that is not a positive decimal" do
      expect { page(actor_id: "abc") }
        .to raise_error(Inspection::Errors::InvalidParameter, /actor_id must be a GitHub id/)
      expect { page(repository_id: "0") }.to raise_error(Inspection::Errors::InvalidParameter)
    end

    # The failure this prevents is silent, which is what makes it worth a guard rather than
    # leaving it to the database. github_actor_id is a signed bigint, and Active Record does
    # not raise when a larger value is bound to a typed column — it casts it and the query
    # returns normally, so an id no row could ever hold yields an empty page a client cannot
    # tell from a genuine miss.
    it "refuses a github id past the bigint the column can hold" do
      expect(page(actor_id: Inspection::BIGINT_MAX.to_s).actor_id)
        .to eq(Inspection::BIGINT_MAX)

      [ Inspection::BIGINT_MAX + 1, 10**24 ].each do |value|
        expect { page(actor_id: value.to_s) }
          .to raise_error(Inspection::Errors::InvalidParameter, /actor_id/)
        expect { page(repository_id: value.to_s) }
          .to raise_error(Inspection::Errors::InvalidParameter, /repository_id/)
      end
    end

    # Unlike the filter above, these two reach the seek predicate as raw binds, where
    # PostgreSQL raises rather than casts: PG::NumericValueOutOfRange for the id and
    # PG::DatetimeFieldOverflow for the year. Either would be a 500 on input the client
    # fully controls.
    it "refuses a cursor the database could not compare against" do
      [ "2026-07-29T12:00:00Z|#{Inspection::BIGINT_MAX + 1}",
        "999999999-01-01T00:00:00Z|42" ].each do |forged|
        expect { page(cursor: Base64.urlsafe_encode64(forged)) }
          .to raise_error(Inspection::Errors::InvalidParameter, /cursor/),
              "expected #{forged.inspect} refused"
      end
    end

    it "still accepts a cursor at the exact edge of what the database can hold" do
      edge = "#{Time.utc(Inspection::MAX_TIMESTAMP_YEAR).iso8601(6)}|#{Inspection::BIGINT_MAX}"

      expect { page(cursor: Base64.urlsafe_encode64(edge)) }.not_to raise_error
    end

    it "refuses a cursor it did not issue" do
      expect { page(cursor: "not-a-cursor") }
        .to raise_error(Inspection::Errors::InvalidParameter, /cursor is not a cursor/)
    end

    # "?repo_id=5" is a plausible typo for repository_id. Ignoring it would answer a
    # question nobody asked with the entire unfiltered feed, while looking exactly like a
    # successful filtered response.
    it "refuses an unknown parameter rather than answering a different question" do
      expect { page(repo_id: "5") }
        .to raise_error(Inspection::Errors::InvalidParameter, /repo_id is not a parameter/)
    end

    it "ignores the keys Rails puts in params itself" do
      expect { page(controller: "api/push_events", action: "index", format: :json) }
        .not_to raise_error
    end
  end

  describe "the guarantee that reading events costs nothing (plan §11)" do
    it "initiates no GitHub request" do
      transport = fixture_transport
      allow(Github).to receive(:transport).and_return(transport)
      expect(Github).not_to receive(:executor)

      page

      expect(transport.requests).to be_empty
    end

    it "issues no write statement" do
      series(2)

      expect(write_statements { page }).to be_empty
    end
  end
end
