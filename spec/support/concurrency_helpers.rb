# Real threads on real PostgreSQL sessions, for the properties that only exist under
# contention.
#
# spec/support/advisory_lock_helpers.rb explains why an *advisory-lock* spec must not use
# threads: with transactional fixtures on, the pool is pinned and every thread is handed the
# same session, so a session lock is re-entrant and a contention assertion silently inverts.
# The budget ledger's contention is different in exactly the way that matters — it is a row
# lock, held inside a transaction — so threads are the right tool, on one condition: the
# spec file must turn transactional tests off, or the pinned pool defeats it the same way.
# Github::BudgetLedger::DEBIT_SQL and its `SELECT … FOR UPDATE` are what these prove, and
# both need genuinely separate sessions to mean anything.
#
# Assertions never run inside a thread. RSpec's expectation failures are exceptions, and one
# raised off the main thread is reported against whatever example happens to be running, or
# swallowed entirely — so every helper here returns data and the example asserts on it.
module ConcurrencyHelpers
  # One fewer than the pool, so a thread never blocks waiting for a connection and turns a
  # contention spec into a pool-exhaustion spec. config/database.yml sizes the pool from
  # RAILS_MAX_THREADS, defaulting to 5, in both compose and CI.
  def parallel_worker_count
    [ ActiveRecord::Base.connection_pool.size - 1, 4 ].min
  end

  # Runs the block once per unit of work, spread across `threads` threads, and returns the
  # results in submission order.
  #
  # Each thread takes its own pooled connection and returns it in an ensure — a leaked lease
  # would starve every example that follows in a random-ordered run. Exceptions are captured
  # rather than raised, because "how many callers were refused, and why" is the assertion in
  # most of these specs, not an error condition.
  #
  # @yieldparam index [Integer] zero-based position of this unit of work
  # @return [Array] each element the block's value, or the exception it raised
  def in_parallel(count, threads: parallel_worker_count)
    queue = Queue.new
    count.times { |index| queue << index }
    results = Array.new(count)

    Array.new(threads) {
      Thread.new do
        loop do
          index = begin
            queue.pop(true)
          rescue ThreadError
            break
          end

          results[index] = ActiveRecord::Base.connection_pool.with_connection { yield index }
        rescue StandardError => e
          results[index] = e
        end
      ensure
        ActiveRecord::Base.connection_pool.release_connection
      end
    }.each(&:join)

    results
  end

  # Puts the pool back the way the rest of the suite needs to find it, and it is not
  # optional.
  #
  # spec/support/advisory_lock_helpers.rb documents the property every other spec leans on:
  # with transactional fixtures the pool is *pinned*, so `checkout` hands the same
  # connection — the same PostgreSQL session — to every thread, and a session advisory lock
  # is therefore re-entrant rather than contended. #in_parallel necessarily breaks that: it
  # opens real additional backends, and they stay in the pool afterwards. A later example
  # that runs code in a job thread then gets a genuinely separate session for the first
  # time, two sessions take the request gate and a source lock in opposite orders, and the
  # run dies on a PostgreSQL deadlock several files away from the cause.
  #
  # The lease is released first because ConnectionPool#disconnect! wants exclusive access
  # and the calling thread is still holding one from the cleanup statements.
  def restore_connection_pool!
    ActiveRecord::Base.connection_pool.release_connection
    ActiveRecord::Base.connection_pool.disconnect!
  end

  # The two outcomes a contended reservation has, counted. Anything that is neither a
  # Github::Errors::BudgetExhausted nor a successful debit is left in :unexpected, so a
  # deadlock, a lock timeout or a LedgerInvariantViolation fails the example loudly instead
  # of being absorbed into the denial count.
  def reservation_outcomes(results)
    granted, refused = results.partition { |result| !result.is_a?(StandardError) }
    denials, unexpected = refused.partition { |error| error.is_a?(Github::Errors::BudgetExhausted) }

    { granted: granted.count, denied: denials.count,
      reasons: denials.map(&:reason).tally, unexpected: unexpected }
  end
end

RSpec.configure do |config|
  config.include ConcurrencyHelpers
end
