module Github
  # PostgreSQL *session*-level advisory locks, held across a whole operation on a
  # retained connection and released in an ensure block (IMPLEMENTATION_PLAN.md §2A).
  #
  # Session-level, never pg_advisory_xact_lock: a transaction-scoped lock ends at
  # transaction end and so cannot own an HTTP operation, and no database transaction
  # may be held open across network I/O. The trade is that nothing releases a session
  # lock implicitly — so every acquisition is a block with an ensure, and hard process
  # or container death releases it by closing the session.
  #
  # Two rules this module exists to make unbreakable:
  #
  #   * A lock is a lexical block scope. Never store a connection or a lock token in
  #     an ivar, a class variable, or a thread-local. Releasing the connection while
  #     the lock is still held is the worst failure available here: session advisory
  #     locks are re-entrant within a session, so the next context to check that
  #     connection out acquires the "same" lock and mutual exclusion silently
  #     disappears, with pg_locks showing one lock and two holders believing they own it.
  #   * The ensure sits *inside* the with_connection block, never outside it.
  module AdvisoryLock
    # classid / objid in pg_locks. 0x475049 is ASCII "GPI"; the low byte separates the
    # two lock families. Literals rather than a hash of a seed string, so
    # `SELECT * FROM pg_locks WHERE locktype = 'advisory'` is readable during an
    # incident without running Ruby to decode the number — and so a diff that changed
    # a seed could not silently change lock identity. Both fit in a signed int32,
    # which PostgreSQL's two-key (int4, int4) form requires.
    SOURCE_LOCK_NAMESPACE = 0x47504901
    REQUEST_GATE_NAMESPACE = 0x47504902

    # The gate is global: one key, always.
    REQUEST_GATE_KEY = 1

    MAX_INT32 = (2**31) - 1

    module_function

    # event_sources.id is bigserial, and the advisory key space is int32. A modulus
    # would alias two sources onto one key, serialising them against each other
    # forever with no test able to notice; a value this large means something is
    # already wrong, so it raises.
    def key_for(event_source_id)
      unless event_source_id.is_a?(Integer) && event_source_id.between?(1, MAX_INT32)
        raise ArgumentError,
              "event_source_id #{event_source_id.inspect} does not fit the int32 advisory key space"
      end

      event_source_id
    end

    # connection_pool#with_connection, never checkout/checkin. If the context already
    # holds a lease — always true inside a job, a controller action, or an RSpec
    # example — this yields that same connection and does not release it, so the lock
    # statements and every query inside the block share one session and pool use stays
    # at one connection per context. A bare #checkout would return a connection outside
    # the lease cache, so the lock would be held on a session doing none of the work.
    #
    # `acquire` raises when the lock is unavailable; it returns the backend PID that
    # owns the lock so release can prove it is unlocking the same session.
    def hold(namespace, key, acquire:)
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        session = acquire.call(connection)

        begin
          LockOrder.track(namespace, key) { yield }
        ensure
          release!(connection, namespace, key, session)
        end
      end
    end

    # exec_query rather than select_value: the Active Record query cache wraps
    # select_all, so a cached `true` from an earlier pg_try_advisory_lock in the same
    # cache scope would let a second acquisition "succeed" without touching the
    # database — the gate would stop gating with no symptom at all.
    def try_lock(connection, namespace, key)
      row = connection.exec_query(
        ActiveRecord::Base.sanitize_sql_array([
          "SELECT pg_try_advisory_lock(?::int, ?::int) AS locked, pg_backend_pid() AS pid",
          namespace, key
        ]),
        "Github::AdvisoryLock TryLock"
      ).first

      row["locked"] ? row["pid"] : nil
    end

    # Blocking acquisition bounded by lock_timeout, which is what gives PostgreSQL's
    # own FIFO wait queue plus a typed, catchable failure. SET LOCAL rather than SET:
    # the GUC is scoped to the transaction and reverts on commit, so a bounded wait can
    # never strand a lock_timeout on a pooled connection that later serves unrelated
    # work — and there is no RESET to forget in an ensure. The session advisory lock
    # deliberately outlives the COMMIT; that is the defining property of a session lock
    # and the reason pg_advisory_xact_lock is not used.
    def lock_with_timeout(connection, namespace, key, wait_seconds)
      ActiveRecord::Base.transaction(requires_new: true) do
        connection.execute(
          ActiveRecord::Base.sanitize_sql_array([ "SET LOCAL lock_timeout = ?", "#{(wait_seconds * 1000).to_i}ms" ]),
          "Github::AdvisoryLock LockTimeout"
        )

        connection.exec_query(
          ActiveRecord::Base.sanitize_sql_array([
            "SELECT pg_advisory_lock(?::int, ?::int), pg_backend_pid() AS pid", namespace, key
          ]),
          "Github::AdvisoryLock Lock"
        ).first.fetch("pid")
      end
    rescue ActiveRecord::LockWaitTimeout
      nil
    end

    def try_with_retry(connection, namespace, key, wait_seconds:, retry_interval:, clock:, sleeper:)
      deadline = clock.call + wait_seconds

      loop do
        session = try_lock(connection, namespace, key)
        return session if session
        return nil if clock.call >= deadline

        sleeper.call(retry_interval)
      end
    end

    # pg_advisory_unlock releases in whatever session executes it, and two things can
    # change the session underneath a held lock: the pool handing out a different
    # connection, and Active Record silently reconnecting a stale one. The second is
    # the dangerous one — the lock is held outside a transaction, so Active Record
    # considers the state restorable, nothing raises, and the lock simply evaporates.
    # So the backend PID is captured at acquisition and re-asserted here, and the
    # unlock's own boolean is checked rather than ignored.
    def release!(connection, namespace, key, expected_session)
      # The unlock is conditional inside the statement, so a session that does not own
      # the lock never issues one: unlocking from the wrong session would release
      # nothing, log a PostgreSQL WARNING, and leave the real holder's lock stranded
      # with no record of who dropped it.
      row = connection.exec_query(
        ActiveRecord::Base.sanitize_sql_array([
          "SELECT pg_backend_pid() AS pid, " \
          "CASE WHEN pg_backend_pid() = ? THEN pg_advisory_unlock(?::int, ?::int) END AS released",
          expected_session, namespace, key
        ]),
        "Github::AdvisoryLock Unlock"
      ).first

      if row["pid"] != expected_session
        raise Errors::LockSessionChanged,
              "advisory lock (#{namespace}, #{key}) was acquired on backend #{expected_session} " \
              "but release was attempted on backend #{row["pid"]}"
      end

      return true if row["released"]

      raise Errors::LockSessionChanged, "advisory lock (#{namespace}, #{key}) was not held at release time"
    end
  end
end
