module Github
  # The global serial gate (IMPLEMENTATION_PLAN.md §2A, §5): at most one live GitHub
  # request in flight across the poller, the worker, and the one-shot. It is what makes
  # budget accounting race-free, and it follows GitHub's own recommendation to make
  # requests serially.
  #
  # One hold wraps exactly one HTTP attempt, so the worst case is
  # HTTP_OPEN_TIMEOUT_SECONDS + HTTP_READ_TIMEOUT_SECONDS. Retries re-acquire the gate
  # rather than extending a hold (§10: each attempt is its own reservation), so a
  # backoff sleep never happens with the gate held.
  class RequestGate
    # Blocking acquisition under a lock_timeout, not a pg_try_advisory_lock poll loop.
    # `try` does not queue, so under real contention — worker, poller, and a reviewer's
    # one-shot all live — it degrades into a lottery that can starve a waiter
    # indefinitely, and it costs a round trip per iteration. Blocking gets PostgreSQL's
    # FIFO wait queue in one round trip. An *unbounded* blocking acquire is rejected
    # for a different reason: it has no failing outcome to assert, so a broken gate
    # spec would hang CI instead of failing it.
    #
    # 45 seconds is longer than any legitimate hold (20s of HTTP timeouts plus two
    # sub-millisecond ledger transactions), so it tolerates a fully queued holder
    # before a waiter defers. A code constant rather than an environment variable:
    # §2A pins the operational defaults, and this one is derived from those.
    WAIT_SECONDS = 45

    class << self
      # @raise [Github::Errors::GateUnavailable] when the gate is not acquired within
      #   wait_seconds. Nothing has been debited at that point, so there is nothing to
      #   unwind — this is a deferral, and treating it as a failure would burn a
      #   healthy source's consecutive_failures on a busy system.
      # @raise [Github::Errors::ReentrantLock] on a nested hold
      # @return [Object] the block's value
      def hold(wait_seconds: WAIT_SECONDS)
        raise ArgumentError, "RequestGate.hold requires a block" unless block_given?

        LockOrder.assert_not_reentrant!(AdvisoryLock::REQUEST_GATE_NAMESPACE,
                                        AdvisoryLock::REQUEST_GATE_KEY, "the request gate")

        acquire_gate = lambda do |connection|
          session = AdvisoryLock.lock_with_timeout(
            connection, AdvisoryLock::REQUEST_GATE_NAMESPACE, AdvisoryLock::REQUEST_GATE_KEY, wait_seconds
          )
          session || raise(Errors::GateUnavailable, "the request gate was not acquired within #{wait_seconds}s")
        end

        AdvisoryLock.hold(AdvisoryLock::REQUEST_GATE_NAMESPACE, AdvisoryLock::REQUEST_GATE_KEY,
                          acquire: acquire_gate) { yield }
      end

      def held?
        LockOrder.holding?(AdvisoryLock::REQUEST_GATE_NAMESPACE, AdvisoryLock::REQUEST_GATE_KEY)
      end
    end
  end
end
