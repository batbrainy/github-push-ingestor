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

  # Takes the lock and returns, with no ensure to undo it — the point of a session-death
  # example is that nothing runs on the way out. #other_session_holding cannot be used for
  # that: its ensure would exec on a connection that no longer exists.
  def acquire_in_other_session(namespace, key)
    second_session.exec_params("SELECT pg_advisory_lock($1::int, $2::int)", [ namespace, key ])
  end

  def second_session_pid
    second_session.exec("SELECT pg_backend_pid()").getvalue(0, 0).to_i
  end

  # Session death the way a container kill produces it: PostgreSQL ends the backend, the
  # client never says goodbye, and no Ruby ensure block runs anywhere. A plain #close is a
  # *disconnect* — the client cooperating — and proves something weaker.
  #
  # Issued through the pooled connection rather than a third socket, so this adds no cleanup
  # surface; the local socket is closed afterwards because its backend is already gone.
  #
  # pg_terminate_backend returns before the backend has finished exiting, so a caller must
  # never assert on the very next line — use the production wait (SourceLock's wait_seconds)
  # or #wait_for_advisory_lock_release.
  # @return [Integer] the pid that was terminated
  def terminate_second_session!
    pid = second_session_pid
    ActiveRecord::Base.connection.exec_query(
      ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_terminate_backend(?)", pid ]),
      "AdvisoryLockHelpers Terminate"
    )
    close_second_session

    pid
  end

  # Which backends hold this lock right now, straight from the server. Uncached, because the
  # query cache would happily answer a second question with the first answer.
  def advisory_lock_holders(namespace, key)
    ActiveRecord::Base.uncached do
      ActiveRecord::Base.connection.select_values(
        ActiveRecord::Base.sanitize_sql_array([ <<~SQL.squish, namespace, key ])
          SELECT pid FROM pg_locks
          WHERE locktype = 'advisory' AND classid::bigint = ? AND objid::bigint = ?
        SQL
      )
    end
  end

  # Bounded, and deliberately not a bare sleep: the release lands within a millisecond or two
  # of the terminate, and if it ever stops landing the example must fail rather than hang.
  def wait_for_advisory_lock_release(namespace, key, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

    until advisory_lock_holders(namespace, key).empty?
      raise "advisory lock #{namespace}:#{key} still held #{timeout}s after session death" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
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

    # Github::LockOrder tracks held locks per execution context, not per connection, and PR 8
    # runs code inside job threads that Solid Queue reuses. A marker left behind by one job
    # would make the *next* job on that thread raise Errors::ReentrantLock for a lock it never
    # took — a non-local failure that is nearly impossible to read backwards. Green today, and
    # the only thing that would catch it.
    tracked = Github::LockOrder.held_keys.dup
    Github::LockOrder.held_keys.clear

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

    raise "Github::LockOrder tracking leaked out of this example: #{tracked.inspect}" if
      leaked.empty? && tracked.any?

    next if leaked.empty?

    ActiveRecord::Base.connection_pool.with_connection { |c| c.execute("SELECT pg_advisory_unlock_all()") }
    raise "advisory lock(s) leaked out of this example: #{leaked.join(", ")}#{" (tracked: #{tracked.inspect})" if tracked.any?}"
  end
end
