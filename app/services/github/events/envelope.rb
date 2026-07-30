module Github
  module Events
    # The two envelope fields every event type shares, read the same way everywhere.
    #
    # Both the registry and the push processor need them, and they need them for
    # different purposes — the registry to route and to classify a structurally broken
    # element, the processor to normalize. A single definition means the rule cannot
    # drift between the two, which matters because github_event_id is what indexes a
    # quarantine row and what deduplicates a push event.
    #
    # Pure readers: they answer "what is usable here?" and never raise, never coerce a
    # shape into something it is not, and never decide an outcome.
    module Envelope
      module_function

      def object?(element)
        element.is_a?(Hash)
      end

      # §7: "GitHub event IDs are large numerics delivered as strings", so the column is
      # text and the value stays text. An Integer is accepted and stringified — tolerance
      # for a delivery change, not for a missing value.
      #
      # @return [String, nil] nil when there is no usable identifier
      def event_id(element)
        return nil unless object?(element)

        raw = element["id"]
        return raw.to_s if raw.is_a?(Integer)

        raw if raw.is_a?(String) && raw.present?
      end

      # Only a non-blank String counts. quarantined_events.event_type is a text column,
      # and an event this application cannot even name is an invalid envelope rather than
      # an event of an unimplemented type (§7 rows 1 and 3).
      #
      # @return [String, nil]
      def event_type(element)
        return nil unless object?(element)

        type = element["type"]
        type if type.is_a?(String) && type.present?
      end
    end
  end
end
