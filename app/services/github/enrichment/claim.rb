module Github
  module Enrichment
    # S3.6: "Prevent duplicate concurrent enrichment (keyed by the entity row)."
    #
    # The fetch happens outside every transaction — §8 forbids one spanning network I/O,
    # and Github::BudgetLedger#assert_committable! raises if one is open — so the claim
    # cannot be a held lock. It is a **lease**: one conditional UPDATE pushes the entity's
    # next_retry_at into the future, and every other reader of that column then treats the
    # row as not attemptable. A crashed worker leaves nothing to clean up; the lease
    # simply expires.
    #
    # Leasing on next_retry_at rather than on a new column is the decision this class
    # rests on, and its payoff is elsewhere: Github::Enrichment::CandidateSelector's two
    # pools and Github::Enrichment::AgeOut's sweep all spell the same
    # "next_retry_at IS NULL OR next_retry_at <= now" clause, so one predicate excludes
    # in-flight rows from all four queries at once. A separate leased_until column would
    # need every one of them to carry a second condition, and the first that forgot would
    # either skip an entity mid-flight or hand it to a second worker.
    #
    # Holds no executor and no transport, so a GitHub request cannot be issued from
    # inside a claim.
    class Claim
      # The candidate statuses each pool may claim from. The pending statement's guard
      # excludes `complete`, so one statement provably cannot serve both pools.
      POOL_STATUSES = {
        pending: Enrichable::CANDIDATE_STATUSES,
        refresh: %w[ complete ]
      }.freeze

      RETURNED_COLUMNS = %w[
        id github_id api_url enrichment_status enrichment_attempts fetched_at last_seen_at
      ].freeze

      # What one worker holds while it fetches.
      class Lease < Data.define(:entity_type, :pool, :id, :github_id, :api_url,
                                :enrichment_status, :enrichment_attempts, :fetched_at,
                                :last_seen_at, :previous_next_retry_at, :leased_until)
        def to_log
          { entity_type: entity_type.key, entity_type.log_key => github_id, pool: pool,
            entity_status: enrichment_status, enrichment_attempt: enrichment_attempts + 1 }
        end
      end

      def initialize(configuration: Github.configuration,
                     selector: CandidateSelector.new(configuration: configuration),
                     gate_wait_seconds: RequestGate::WAIT_SECONDS)
        @configuration = configuration
        @selector = selector
        @gate_wait_seconds = gate_wait_seconds
      end

      attr_reader :configuration, :selector

      # @param entity_type [Github::Enrichment::EntityType]
      # @param pool [Symbol] :pending or :refresh
      # @return [Lease, nil] nil when nothing was claimable — an empty pool, or a race
      #   another worker won.
      def acquire(entity_type, pool:, now:)
        statuses = POOL_STATUSES.fetch(pool) { raise ArgumentError, "unknown pool #{pool.inspect}" }
        leased_until = now + lease_seconds

        row = execute(claim_sql(entity_type, pool: pool, statuses: statuses, now: now,
                                leased_until: leased_until),
                      "Github::Enrichment::Claim Acquire").first
        return nil if row.nil?

        build_lease(entity_type, pool, row)
      end

      # Undoes a claim that never became an attempt: a budget denial, a busy gate, or a
      # corpus gap. It restores the *exact* prior instant and writes nothing else — no
      # attempt count, no error, no status, not even updated_at — so a deferred cycle
      # leaves the row byte-for-byte as it found it. §7's "failures stay spent" has a
      # mirror here: deferrals leave no trace.
      #
      # Restoring rather than nulling is behaviourally identical (the claim guard proves
      # the prior value was NULL or already past), but nulling would erase when the entity
      # last backed off, from a code path that performed no fetch.
      #
      # The next_retry_at guard is load-bearing, not defensive: lease_seconds is the
      # worst-case runtime by construction, so a lease expiring mid-flight is reachable,
      # and an ungarded late release would clear another worker's fresh lease.
      # @return [Boolean] whether this lease was still held
      def release!(lease)
        updated = ActiveRecord::Base.connection.exec_update(
          ActiveRecord::Base.sanitize_sql_array([ <<~SQL.squish, lease.previous_next_retry_at, lease.id, lease.leased_until ]),
            UPDATE #{lease.entity_type.table_name} SET next_retry_at = ? WHERE id = ? AND next_retry_at = ?
          SQL
          "Github::Enrichment::Claim Release"
        )

        updated == 1
      end

      # Derived rather than chosen, following RequestGate::WAIT_SECONDS' precedent — §2A
      # pins the operational defaults and this follows from them. Every term is a real
      # component's worst case: one gated attempt may wait the whole gate timeout plus
      # both HTTP timeouts; each retry restarts redirect following from the original
      # request (Github::RequestExecutor#follow_redirects); and the backoff sleeps between
      # attempts still consume wall clock.
      #
      # At the pinned defaults: 3 attempts x 3 hops x (45 + 5 + 15) + 8.75 = 594 seconds.
      def lease_seconds
        attempts = 1 + configuration.max_http_retries
        hops = 1 + configuration.max_redirects
        per_request = @gate_wait_seconds +
                      configuration.http_open_timeout_seconds +
                      configuration.http_read_timeout_seconds
        backoff = RetryPolicy::RETRY_BASE_DELAY_SECONDS *
                  ((2**attempts) - 1) * (1 + RetryPolicy::RETRY_JITTER_FRACTION)

        ((attempts * hops * per_request) + backoff).ceil
      end

      private

      # The candidate CTE is Github::Enrichment::CandidateSelector's own scope, so the
      # eligibility window, the TTL, and §10's two ordering rules are defined in exactly
      # one place and this statement cannot drift from the pool it claims out of.
      #
      # Three details carry the correctness:
      #
      #   1. FOR UPDATE SKIP LOCKED turns "correct" into "makes progress". Without it two
      #      workers pick the same row and one wastes a cycle; with it the second takes
      #      the next-best candidate. PR 8 runs several, so this matters.
      #   2. The status and due guards are repeated on the *outer* UPDATE. Under READ
      #      COMMITTED a blocked UPDATE re-evaluates its quals against the newly committed
      #      row version, and `entities.id = candidate.id` alone is a constant that would
      #      pass — letting the second worker overwrite the first one's lease. Repeating
      #      the guards makes the re-check reject. The CTE's FOR UPDATE performs its own
      #      re-check too, so this is belt and braces; keeping it means the safety claim
      #      needs no argument about PostgreSQL internals.
      #   3. RETURNING takes the *prior* instant from the CTE snapshot. PostgreSQL 16 has
      #      no RETURNING OLD.*, and entities.next_retry_at would hand back the lease we
      #      just wrote rather than the value a release has to restore.
      #
      # updated_at is deliberately absent from the SET list. GithubActor::IDENTITY_MERGE
      # gates every identity refresh on `EXCLUDED.updated_at >= github_actors.updated_at`,
      # so bumping it here would make a concurrently-processed page whose received_at
      # predates the lease silently lose its refresh — to a write that may be released a
      # second later. updated_at moves on writes that change the entity's observable
      # state, and a lease is not observable state.
      def claim_sql(entity_type, pool:, statuses:, now:, leased_until:)
        table = entity_type.table_name
        candidate = selector.scope(entity_type, pool: pool, now: now)
                            .select(:id, :next_retry_at).limit(1).lock("FOR UPDATE SKIP LOCKED").to_sql
        returned = RETURNED_COLUMNS.map { |column| "entities.#{column}" }.join(", ")

        ActiveRecord::Base.sanitize_sql_array([ <<~SQL.squish, leased_until, statuses, now ])
          WITH candidate AS (#{candidate})
          UPDATE #{table} AS entities
             SET next_retry_at = ?
            FROM candidate
           WHERE entities.id = candidate.id
             AND entities.enrichment_status IN (?)
             AND (entities.next_retry_at IS NULL OR entities.next_retry_at <= ?)
        RETURNING #{returned}, entities.next_retry_at AS leased_until,
                  candidate.next_retry_at AS previous_next_retry_at
        SQL
      end

      def execute(sql, name)
        ActiveRecord::Base.connection.exec_query(sql, name)
      end

      # The two instants come back from RETURNING rather than from Ruby, so the lease this
      # object holds is byte-identical to what PostgreSQL stored — which is what makes the
      # `next_retry_at = ?` guards in #release! and in Github::Enrichment::EntityState
      # exact rather than dependent on timestamp rounding.
      def build_lease(entity_type, pool, row)
        Lease.new(
          entity_type: entity_type,
          pool: pool,
          id: row.fetch("id"),
          github_id: row.fetch("github_id"),
          api_url: row.fetch("api_url"),
          enrichment_status: row.fetch("enrichment_status"),
          enrichment_attempts: row.fetch("enrichment_attempts"),
          fetched_at: timestamp(row.fetch("fetched_at")),
          last_seen_at: timestamp(row.fetch("last_seen_at")),
          previous_next_retry_at: timestamp(row.fetch("previous_next_retry_at")),
          leased_until: timestamp(row.fetch("leased_until"))
        )
      end

      # exec_query bypasses the attribute types a model would apply, so a timestamp comes
      # back as whatever the adapter produced.
      def timestamp(value)
        return nil if value.nil?
        return value if value.is_a?(Time)

        Time.zone.parse(value.to_s)
      end
    end
  end
end
