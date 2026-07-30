module Github
  # Ownership of one event source for the duration of a complete polling operation
  # (IMPLEMENTATION_PLAN.md §2A, §9). Polling only: enrichment requests belong to no
  # event source and never take this lock (§5, Appendix D item 1).
  #
  # A `FOR UPDATE` row claim cannot own an HTTP operation, because a row lock ends at
  # transaction end and a transaction must not span network I/O. A session advisory
  # lock gives operation-wide ownership that PostgreSQL releases automatically when
  # the session dies — which is what makes a hard container kill safe. Verifying that
  # release-on-death behaviour is PR 8's half of B7; PR 4 delivers acquisition.
  #
  # PR 5's IngestionRunner is the first caller; the one-shot ingestion command is the
  # second.
  class SourceLock
    # The poller attempts once and exits (§2A); the one-shot retries up to
    # SOURCE_LOCK_WAIT_SECONDS (§9). Both use pg_try_advisory_lock — a plain blocking
    # pg_advisory_lock here has no upper bound at all, since the holder's operation is
    # MAX_PAGES_PER_POLL requests plus retries, and it would pin both a worker thread
    # and a pool connection behind a holder that legitimately owns the source.
    POLLER_WAIT_SECONDS = 0
    RETRY_INTERVAL_SECONDS = 0.25

    # CLOCK_MONOTONIC, not Time.current: an NTP step or a container suspend must not
    # truncate or extend the wait. Both collaborators are injected so the one-shot's
    # 30-second contract is asserted in zero wall-clock time.
    MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    SLEEPER = ->(seconds) { Kernel.sleep(seconds) }

    class << self
      # @raise [Github::Errors::SourceBusy] when the lock is unavailable within
      #   wait_seconds. Busy is a deferral, not a failure: the poller exits and tries
      #   again next cycle, and the one-shot prints its state summary and exits 0 (§9).
      # @raise [Github::Errors::LockOrderViolation] when the request gate is held
      # @return [Object] the block's value
      def acquire(event_source_id,
                  wait_seconds: POLLER_WAIT_SECONDS,
                  retry_interval: RETRY_INTERVAL_SECONDS,
                  clock: MONOTONIC,
                  sleeper: SLEEPER)
        raise ArgumentError, "SourceLock.acquire requires a block" unless block_given?

        key = AdvisoryLock.key_for(event_source_id)
        assert_lock_order!
        LockOrder.assert_not_reentrant!(AdvisoryLock::SOURCE_LOCK_NAMESPACE, key,
                                        "the source lock for event source #{key}")

        acquire_lock = lambda do |connection|
          session = AdvisoryLock.try_with_retry(
            connection, AdvisoryLock::SOURCE_LOCK_NAMESPACE, key,
            wait_seconds: wait_seconds, retry_interval: retry_interval, clock: clock, sleeper: sleeper
          )
          session || raise(Errors::SourceBusy, "event source #{key} is locked by another session")
        end

        AdvisoryLock.hold(AdvisoryLock::SOURCE_LOCK_NAMESPACE, key, acquire: acquire_lock) { yield }
      end

      def held?(event_source_id)
        LockOrder.holding?(AdvisoryLock::SOURCE_LOCK_NAMESPACE, event_source_id)
      end

      private

      # The lock-order invariant, enforced rather than documented: taking a source lock
      # while holding the global gate is the path that deadlocks two containers with
      # nothing in the logs.
      def assert_lock_order!
        return unless LockOrder.holding?(AdvisoryLock::REQUEST_GATE_NAMESPACE)

        raise Errors::LockOrderViolation,
              "the source lock may not be acquired while the request gate is held " \
              "(plan §5: source lock -> request gate, never the reverse)"
      end
    end
  end
end
