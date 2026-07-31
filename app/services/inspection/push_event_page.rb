module Inspection
  # One page of GET /api/push_events (IMPLEMENTATION_PLAN.md §11): parameter parsing, the
  # keyset query, and the answer to "is there a next page", as a value object the controller
  # only renders.
  #
  # **It never initiates a GitHub request** — §11's standing guarantee for the whole
  # health-and-inspection surface — and it is structural in exactly the way
  # Github::Ingestion::StateSummary's is: no executor, no transport, no ledger, and its only
  # collaborator is PushEvent. It also never writes; there is nothing here that could.
  #
  # .for takes anything answering #keys and #[], so a spec can pass a plain Hash and never
  # construct ActionController::Parameters.
  class PushEventPage < Data.define(:records, :limit, :cursor, :actor_id,
                                    :repository_id, :next_cursor)
    DEFAULT_LIMIT = 25

    # A page costs the same three statements regardless of size — the keyset SELECT plus two
    # preloads — so the thing that scales is the row count. 100 rows without raw_payload is
    # still a response a human can read, and it is the ceiling GitHub's own list endpoints
    # use.
    MAX_LIMIT = 100

    PERMITTED = %w[limit cursor actor_id repository_id].freeze

    # Rails' own, never the client's. format is here because the route declares
    # defaults: { format: :json }.
    RESERVED = %w[controller action format].freeze

    # \A\d+\z rather than Kernel#Integer, and the difference is not pedantry:
    # Integer("010") is 8, Integer("0x10") is 22 and Integer("1_0") is 10, so three
    # different query strings would silently mean something other than what they read as.
    # These parameters are decimal or they are refused.
    DECIMAL = /\A\d+\z/

    class << self
      def for(params)
        reject_unknown!(params)

        build(
          limit: parse_limit(params[:limit]),
          cursor: parse_cursor(params[:cursor]),
          actor_id: parse_github_id(:actor_id, params[:actor_id]),
          repository_id: parse_github_id(:repository_id, params[:repository_id])
        )
      end

      private

      def build(limit:, cursor:, actor_id:, repository_id:)
        # limit + 1, then discard the extra. That one row is the entire evidence a next page
        # exists, and it costs one tuple; the alternative is a second statement whose
        # COUNT(*) is a sequential scan over an append-only table, on every request.
        rows = relation(cursor: cursor, actor_id: actor_id, repository_id: repository_id)
                 .limit(limit + 1)
                 .to_a
        records = rows.first(limit)

        new(records: records, limit: limit, cursor: cursor,
            actor_id: actor_id, repository_id: repository_id,
            next_cursor: rows.length > limit ? Cursor.from(records.last) : nil)
      end

      def relation(cursor:, actor_id:, repository_id:)
        # preload, not eager_load: two additional IN (…) statements against the unique
        # index_github_*_on_github_id, rather than a two-way LEFT JOIN whose wide rows would
        # then have to be de-duplicated. Both associations declare primary_key: :github_id,
        # which preloading honours.
        #
        # id DESC is not decoration. occurred_at is not unique — one poll commits a whole
        # page of events, and several corpus events share an instant — so without the
        # tiebreak the order inside a group is whatever the plan happens to produce, and a
        # paging client would see rows twice or not at all.
        scope = PushEvent.preload(:github_actor, :github_repository)
                         .order(occurred_at: :desc, id: :desc)
        scope = scope.where(github_actor_id: actor_id) if actor_id
        scope = scope.where(github_repository_id: repository_id) if repository_id
        cursor ? seek(scope, cursor) : scope
      end

      # Not "(occurred_at, id) < (?, ?)". The row-value form is equivalent and reads better,
      # but PostgreSQL only pushes a row comparison into an index when a matching
      # *multicolumn* index exists, and this schema carries only
      # index_push_events_on_occurred_at — so that form degrades to a filter over a full
      # scan. This form splits it: occurred_at <= ? is a plain range predicate the existing
      # index drives directly, and the parenthesised clause is a cheap recheck over the rows
      # it returns.
      #
      # The follow-up, when volume demands it, is an index on (occurred_at, id) and a
      # rewrite to the row-value form — the same "no index until a query demands one"
      # posture spec/db/schema_spec.rb already takes on raw_payload.
      def seek(scope, cursor)
        scope.where(
          "push_events.occurred_at <= :at AND " \
          "(push_events.occurred_at < :at OR push_events.id < :id)",
          at: cursor.occurred_at, id: cursor.id
        )
      end

      # Blank means absent, for every parameter: "?limit=" is what a form serialiser emits
      # for an untouched field, and refusing it would fail a client that asked for nothing
      # unusual.
      def parse_limit(value)
        return DEFAULT_LIMIT if value.blank?

        # Refused rather than clamped to MAX_LIMIT. Clamping makes the response lie about
        # what was asked — a client that requested 500 and received 100 cannot tell whether
        # it received everything — and §16 rules out exactly that kind of misleading answer.
        # The ceiling is named in the message so the correction takes one round trip.
        unless value.to_s.match?(DECIMAL) && value.to_i.between?(1, MAX_LIMIT)
          raise Errors::InvalidParameter.new(:limit, "must be an integer from 1 to #{MAX_LIMIT}")
        end

        value.to_i
      end

      def parse_cursor(value)
        return nil if value.blank?

        Cursor.decode(value) ||
          raise(Errors::InvalidParameter.new(:cursor, "is not a cursor this endpoint issued"))
      end

      # The upper bound is not belt and braces. github_actor_id and github_repository_id are
      # signed bigints, and Active Record does *not* raise when a larger value is bound to a
      # typed column — it casts it and the query returns normally, so an id no row could ever
      # hold produces an empty page indistinguishable from a genuine miss. Refusing it here
      # is the only way the client gets the documented 400 rather than a plausible lie.
      def parse_github_id(name, value)
        return nil if value.blank?

        unless value.to_s.match?(DECIMAL) && value.to_i.between?(1, BIGINT_MAX)
          raise Errors::InvalidParameter.new(name, "must be a GitHub id from 1 to #{BIGINT_MAX}")
        end

        value.to_i
      end

      # Refused, not ignored. "?repo_id=5" is a plausible typo for repository_id, and
      # ignoring it answers a question nobody asked with the entire unfiltered feed while
      # looking exactly like a successful filtered response. #keys rather than
      # #to_unsafe_h so this stays a Hash-friendly value object.
      def reject_unknown!(params)
        unknown = params.keys.map(&:to_s) - PERMITTED - RESERVED
        return if unknown.empty?

        raise Errors::InvalidParameter.new(unknown.min,
                                           "is not a parameter this endpoint accepts")
      end
    end
  end
end
