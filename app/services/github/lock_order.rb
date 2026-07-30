module Github
  # The registry that makes the lock-order invariant checkable at runtime.
  #
  # IMPLEMENTATION_PLAN.md §2A, §5 and CLAUDE.md all state the same rule — source lock
  # then request gate, never the reverse — and until now nothing enforced it. Its only
  # guarantee was structural: RequestExecutor is never handed an event_source_id, a
  # separation Appendix D item 1 introduced deliberately. Structure erodes under
  # maintenance; a raise does not.
  #
  # Held keys are tracked per execution context rather than per connection, because
  # lock ordering is by definition an intra-thread property: a cycle needs one context
  # holding A and wanting B while another holds B and wants A, and every such path is
  # code inside one context. This is exact only because the design gives each context
  # exactly one connection (Github::AdvisoryLock always leases through
  # connection_pool#with_connection); if a future path ever held two, the marker would
  # become advisory rather than exact.
  #
  # ActiveSupport::IsolatedExecutionState rather than Thread.current, so it honours
  # config.active_support.isolation_level and is what Active Record itself uses for
  # connection lease context.
  module LockOrder
    HELD_KEYS = :github_held_advisory_locks

    module_function

    def held_keys
      ActiveSupport::IsolatedExecutionState[HELD_KEYS] ||= []
    end

    # With a key: "is this exact lock held?" — a re-entrancy check. Without one: "is
    # any lock of this family held?" — the ordering check.
    def holding?(namespace, key = nil)
      key.nil? ? held_keys.any? { |(held, _)| held == namespace } : held_keys.include?([ namespace, key ])
    end

    def track(namespace, key)
      held_keys.push([ namespace, key ])
      yield
    ensure
      held_keys.delete_at(held_keys.rindex([ namespace, key ]) || held_keys.length - 1)
    end

    # PostgreSQL session advisory locks are re-entrant: a second acquisition of a key
    # this session already holds returns true. For the gate that would silently permit
    # two in-flight requests from one context, so re-entrancy is refused rather than
    # counted.
    def assert_not_reentrant!(namespace, key, description)
      return unless holding?(namespace, key)

      raise Errors::ReentrantLock, "#{description} is already held on this execution context"
    end
  end
end
