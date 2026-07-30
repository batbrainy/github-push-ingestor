# Advisory-lock specs need a genuinely separate PostgreSQL session, and they must not
# use a thread to get one.
#
# While use_transactional_fixtures has the pool pinned, ConnectionPool#checkout returns
# the pinned connection to every thread — so a second thread shares the first thread's
# session, and session advisory locks are re-entrant within a session. A thread-based
# contention example would therefore pass no matter what the production code does,
# including if RequestGate.hold were an empty method.
#
# An out-of-pool connection is a real second session, consumes no pool slot (the suite
# passes at RAILS_MAX_THREADS=1), and keeps every example synchronous: no sleeps, no
# joins, no ordering assumptions. Advisory locks are not transactional state, so the
# second session can observe them without needing to see the example's uncommitted rows.
module AdvisoryLockHelpers
  def second_session
    @second_session ||= begin
      config = ActiveRecord::Base.connection_db_config.configuration_hash

      PG::Connection.new(
        host: config[:host], port: config[:port], user: config[:username],
        password: config[:password], dbname: config[:database]
      )
    end
  end

  # "Could another process take this lock right now?" Acquires and immediately releases,
  # so it stays a pure predicate.
  def lock_available_to_other_session?(namespace, key)
    acquired = second_session
      .exec_params("SELECT pg_try_advisory_lock($1::int, $2::int)", [ namespace, key ])
      .getvalue(0, 0) == "t"

    release_in_other_session(namespace, key) if acquired
    acquired
  end

  def other_session_holding(namespace, key)
    second_session.exec_params("SELECT pg_advisory_lock($1::int, $2::int)", [ namespace, key ])
    yield
  ensure
    release_in_other_session(namespace, key)
  end

  def release_in_other_session(namespace, key)
    second_session.exec_params("SELECT pg_advisory_unlock($1::int, $2::int)", [ namespace, key ])
  end

  def close_second_session
    @second_session&.close
    @second_session = nil
  end

  # A scripted clock and a no-op sleeper, so a wait contract is asserted in zero
  # wall-clock time. Readings are consumed in order: the first is the deadline
  # baseline, then one per loop turn.
  def scripted_clock(*readings)
    -> { readings.shift }
  end
end

RSpec.configure do |config|
  config.include AdvisoryLockHelpers

  # Session advisory locks survive transaction rollback, and ConnectionPool#checkin
  # expires the lease without resetting the connection — so a lock leaked by one
  # example rides the pinned connection into the next, where a re-entrant re-acquire
  # succeeds and a contention assertion silently inverts. Fail the leaking example, and
  # clean up so the failure does not cascade through the rest of a random-ordered run.
  config.after do
    close_second_session

    namespaces = [ Github::AdvisoryLock::SOURCE_LOCK_NAMESPACE, Github::AdvisoryLock::REQUEST_GATE_NAMESPACE ]

    # An example that made the connection unavailable — spec/requests/health_spec.rb
    # stubs the pool to prove /health/ready degrades — cannot be asked about pg_locks,
    # and never took a lock through the connection it removed.
    leaked = begin
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.select_values(
          ActiveRecord::Base.sanitize_sql_array([ <<~SQL.squish, namespaces ])
            SELECT classid || ':' || objid FROM pg_locks
            WHERE locktype = 'advisory' AND pid = pg_backend_pid() AND classid::bigint IN (?)
          SQL
        )
      end
    rescue ActiveRecord::ActiveRecordError
      []
    end

    next if leaked.empty?

    ActiveRecord::Base.connection_pool.with_connection { |c| c.execute("SELECT pg_advisory_unlock_all()") }
    raise "advisory lock(s) leaked out of this example: #{leaked.join(", ")}"
  end
end
