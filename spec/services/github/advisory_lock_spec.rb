require "rails_helper"

RSpec.describe Github::AdvisoryLock do
  describe "the namespaces" do
    # PostgreSQL's two-key advisory form takes two int4 values. A namespace outside
    # that range would be truncated silently rather than rejected.
    it "gives each lock family a distinct key inside the signed int32 space" do
      namespaces = [ described_class::SOURCE_LOCK_NAMESPACE, described_class::REQUEST_GATE_NAMESPACE ]

      expect(namespaces.uniq.size).to eq(2)
      expect(namespaces).to all(be_between(1, described_class::MAX_INT32))
    end

    # Literals rather than a hash of a seed string, so pg_locks is readable during an
    # incident and a changed seed cannot silently move lock identity.
    it "is greppable in pg_locks as the classid of a held lock" do
      Github::RequestGate.hold do
        classids = ActiveRecord::Base.connection.select_values(<<~SQL.squish)
          SELECT classid::bigint FROM pg_locks
          WHERE locktype = 'advisory' AND pid = pg_backend_pid()
        SQL

        expect(classids).to include(described_class::REQUEST_GATE_NAMESPACE)
      end
    end
  end

  describe ".key_for" do
    it "accepts an ordinary event source id" do
      expect(described_class.key_for(42)).to eq(42)
    end

    # event_sources.id is bigserial. A modulus would alias two sources onto one key,
    # serialising them against each other forever with no test able to notice.
    it "refuses an id past int32 instead of aliasing two sources onto one key" do
      expect { described_class.key_for(described_class::MAX_INT32 + 1) }
        .to raise_error(ArgumentError, /int32 advisory key space/)
    end

    it "refuses a non-integer id" do
      expect { described_class.key_for("7") }.to raise_error(ArgumentError)
    end
  end

  describe ".hold" do
    let(:namespace) { described_class::SOURCE_LOCK_NAMESPACE }
    let(:key) { 4242 }

    def hold(&block)
      described_class.hold(namespace, key, acquire: ->(connection) {
        described_class.try_lock(connection, namespace, key) || raise(Github::Errors::SourceBusy)
      }, &block)
    end

    it "excludes another session for the duration of the block, and only then" do
      available_inside = nil

      hold { available_inside = lock_available_to_other_session?(namespace, key) }

      expect(available_inside).to be(false)
      expect(lock_available_to_other_session?(namespace, key)).to be(true)
    end

    # Nothing releases a session advisory lock implicitly, so the ensure is the only
    # thing standing between an exception and a source that stays unpollable until the
    # process dies.
    it "releases the lock when the block raises" do
      expect { hold { raise "boom" } }.to raise_error("boom")

      expect(lock_available_to_other_session?(namespace, key)).to be(true)
    end

    it "returns the block's value" do
      expect(hold { :polled }).to eq(:polled)
    end
  end

  describe ".try_lock" do
    let(:namespace) { described_class::SOURCE_LOCK_NAMESPACE }
    let(:key) { 4343 }

    it "reports failure when another session already holds the key" do
      other_session_holding(namespace, key) do
        session = ActiveRecord::Base.connection_pool.with_connection do |connection|
          described_class.try_lock(connection, namespace, key)
        end

        expect(session).to be_nil
      end
    end

    # The Active Record query cache wraps select_all — and therefore select_value —
    # so an identical lock query issued twice inside one cache scope would be answered
    # from the cache the second time. Whichever answer was cached is then wrong: a
    # cached "held by someone else" locks this process out of a lock that is now free,
    # and a cached "acquired" hands two holders the same gate. exec_query bypasses that
    # layer entirely.
    #
    # The two attempts below have genuinely different correct answers and nothing
    # between them that could clear the cache, which is what makes this a detector
    # rather than a description.
    it "reaches the database even inside a query cache scope" do
      ActiveRecord::Base.cache do
        second_session.exec_params("SELECT pg_advisory_lock($1::int, $2::int)", [ namespace, key ])

        blocked = ActiveRecord::Base.connection_pool.with_connection do |connection|
          described_class.try_lock(connection, namespace, key)
        end
        expect(blocked).to be_nil

        release_in_other_session(namespace, key)

        granted = ActiveRecord::Base.connection_pool.with_connection do |connection|
          described_class.try_lock(connection, namespace, key)
        end
        expect(granted).not_to be_nil

        ActiveRecord::Base.connection_pool.with_connection do |connection|
          described_class.release!(connection, namespace, key, granted)
        end
      end
    end
  end

  describe ".release!" do
    let(:namespace) { described_class::SOURCE_LOCK_NAMESPACE }
    let(:key) { 4444 }

    # The pool substituting a connection, or Active Record silently reconnecting a
    # stale one, would make the unlock land on a session that never held the lock. The
    # lock is then orphaned, and continuing quietly would let a second poller believe
    # it owns the source.
    it "refuses to unlock from a session other than the one that acquired the lock" do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        session = described_class.try_lock(connection, namespace, key)

        expect { described_class.release!(connection, namespace, key, session + 1) }
          .to raise_error(Github::Errors::LockSessionChanged, /backend/)

        described_class.release!(connection, namespace, key, session)
      end
    end

    # An unheld unlock returns false plus a PostgreSQL WARNING, which is otherwise pure
    # log noise nobody reads.
    it "refuses when the lock was not held at release time" do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        session = connection.select_value("SELECT pg_backend_pid()")

        expect { described_class.release!(connection, namespace, key, session) }
          .to raise_error(Github::Errors::LockSessionChanged, /not held/)
      end
    end
  end

  describe ".try_with_retry" do
    let(:namespace) { described_class::SOURCE_LOCK_NAMESPACE }
    let(:key) { 4545 }

    # A scripted clock and a recording sleeper, so the wait contract costs no
    # wall-clock time and cannot flake on a slow CI box.
    it "retries until its deadline and then reports failure" do
      slept = []

      other_session_holding(namespace, key) do
        session = ActiveRecord::Base.connection_pool.with_connection do |connection|
          described_class.try_with_retry(
            connection, namespace, key,
            wait_seconds: 0.75, retry_interval: 0.25,
            clock: scripted_clock(0.0, 0.0, 0.25, 0.50, 1.00), sleeper: ->(seconds) { slept << seconds }
          )
        end

        expect(session).to be_nil
        expect(slept).to eq([ 0.25, 0.25, 0.25 ])
      end
    end

    it "does not sleep at all when the lock is free on the first attempt" do
      slept = []

      session = ActiveRecord::Base.connection_pool.with_connection do |connection|
        acquired = described_class.try_with_retry(
          connection, namespace, key,
          wait_seconds: 30, retry_interval: 0.25,
          clock: scripted_clock(0.0), sleeper: ->(seconds) { slept << seconds }
        )
        described_class.release!(connection, namespace, key, acquired)
        acquired
      end

      expect(session).not_to be_nil
      expect(slept).to be_empty
    end
  end
end
