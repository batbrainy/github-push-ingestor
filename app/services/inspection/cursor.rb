module Inspection
  # Keyset pagination's position marker: the (occurred_at, id) of the last row a page
  # returned.
  #
  # Opaque rather than two plain query parameters, for a reason specific to this schema.
  # The tiebreak has to be the surrogate primary key — occurred_at is not unique, since one
  # poll commits a whole page of events, and github_event_id is text with no ordering index
  # — but IMPLEMENTATION_PLAN.md §7 keeps that surrogate key out of this application's
  # identity vocabulary entirely, to the point that even the foreign keys target github_id.
  # Encoding it keeps the ordering contract on the server and makes a client that hard-codes
  # "id > n" impossible to write.
  #
  # This is encoding, not security. Nothing is signed and nothing needs to be: .decode
  # yields a Time and a non-negative Integer or it yields nil, and both reach PostgreSQL as
  # bound parameters. A forged cursor can only ask for a different page of public data.
  #
  # Base64 needs no Gemfile entry — activesupport already depends on it.
  class Cursor < Data.define(:occurred_at, :id)
    SEPARATOR = "|".freeze

    # Microseconds, because push_events.occurred_at is timestamp(6). Truncating to whole
    # seconds would make the cursor ambiguous inside a single second — which is exactly the
    # window one poll writes an entire page of events into, and therefore exactly where a
    # page boundary is most likely to fall.
    PRECISION = 6

    class << self
      def from(record)
        new(occurred_at: record.occurred_at, id: record.id)
      end

      # @return [Cursor, nil] nil for anything this cannot read. The caller turns that into
      #   a 400 rather than silently restarting from the top: a paging client that corrupts
      #   its cursor and gets page one back would loop forever without ever seeing an error.
      def decode(value)
        return nil if value.blank?

        timestamp, id = Base64.urlsafe_decode64(value.to_s).split(SEPARATOR, 2)
        return nil unless timestamp.present? && id.to_s.match?(/\A\d+\z/)

        new(occurred_at: Time.iso8601(timestamp), id: Integer(id, 10))
      rescue ArgumentError
        # Both urlsafe_decode64 and Time.iso8601 signal unreadable input this way.
        nil
      end
    end

    def encode
      Base64.urlsafe_encode64(
        "#{occurred_at.utc.iso8601(PRECISION)}#{SEPARATOR}#{id}", padding: false
      )
    end
  end
end
