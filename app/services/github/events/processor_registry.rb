module Github
  module Events
    # The event processor registry (IMPLEMENTATION_PLAN.md §5, §6, §13).
    #
    # §6: "The event processor registry will initially support only PushEvent… Configured
    # event types must be validated against implemented processors. Unsupported types
    # should fail fast with a clear configuration error."
    #
    # It deliberately mirrors Github::EventSources::Base.registry / .for — down to the
    # shape of the error message — so a reviewer who has read the first seam recognizes
    # the second. Both answer the same question about a different axis: which
    # implementation serves this name, and what happens when none does.
    #
    # This class owns exactly the **type-agnostic** half of §7's taxonomy, because that is
    # the part that does not depend on any event's payload shape:
    #
    #   element is not an object ......... quarantined, invalid_envelope    (§7 row 3)
    #   no usable type .................. quarantined, missing_event_type   (§7 row 3)
    #   a type no processor implements ... ignored and counted              (§7 row 1)
    #   otherwise ....................... delegated to the processor
    #
    # Type before field checks is load-bearing. Roughly nine in ten events on the global
    # feed are not pushes; running payload checks first would quarantine all of them for
    # lacking payload.head, and §7 is explicit that a valid non-PushEvent is "Ignored and
    # counted — not quarantined".
    #
    # A malformed event of an unimplemented type is still ignored, and that is a decision
    # rather than an oversight: this application has no WatchEvent processor and therefore
    # no definition of a valid WatchEvent. Validating fields it never persists would
    # invent a schema for twenty-odd unverified event types and fill the quarantine table
    # with rows no operator can act on. For an unprocessed type, "valid" can only mean
    # "identifiable" — a Hash with a nameable type.
    class ProcessorRegistry
      class << self
        # @return [Hash{String => Class}] implemented processors by event type
        def registry
          @registry ||= { PushEventProcessor.event_type => PushEventProcessor }.freeze
        end

        def implemented_types
          registry.keys.sort
        end

        # Every implemented processor. The runner's default: §16's functional gate is
        # "Only PushEvent records are processed", and exactly one processor exists.
        def default
          new(processors: registry.each_value.map(&:new))
        end

        # §6's configuration validation. There is no GITHUB_EVENT_TYPES environment
        # variable: one processor ships, so the only value that would pass is the default,
        # and §16 forbids dead or speculative infrastructure. This method is the
        # validation §6 requires, ready for the day a second processor makes the variable
        # meaningful — at which point it is one DEFAULTS entry and one #validate! line.
        #
        # @param event_types [Array<String>, String]
        # @raise [Github::Errors::ConfigurationError] naming every unimplemented type
        def for(event_types)
          requested = Array(event_types).map { |type| type.to_s.strip }.reject(&:empty?)
          raise Errors::ConfigurationError, "no event types were configured to process" if requested.empty?

          unimplemented = requested - registry.keys
          if unimplemented.any?
            raise Errors::ConfigurationError,
                  "no event processor implements #{unimplemented.sort.join(", ")}; " \
                  "implemented types: #{implemented_types.join(", ")}"
          end

          new(processors: requested.uniq.map { |type| registry.fetch(type).new })
        end
      end

      # Duck-typed on real objects rather than enforced by an abstract base class with one
      # subclass — the speculation critique Appendix A item 7 upheld the design against
      # applies here too.
      def initialize(processors:)
        @processors = processors.to_h do |processor|
          unless processor.class.respond_to?(:event_type) && processor.respond_to?(:call)
            raise ArgumentError, "#{processor.class} must declare .event_type and respond to #call"
          end

          [ processor.class.event_type, processor ]
        end.freeze
      end

      def event_types
        @processors.keys
      end

      def handles?(event_type)
        @processors.key?(event_type)
      end

      # @param element [Object] one decoded array element, exactly as
      #   Github::EventSources::Base#events returned it — including nil
      # @return [Github::Events::Outcome]
      def process(element)
        return invalid_envelope(element) unless Envelope.object?(element)

        event_type = Envelope.event_type(element)
        return missing_event_type(element) if event_type.nil?

        processor = @processors[event_type]
        return ignored(element, event_type) if processor.nil?

        processor.call(element)
      end

      private

      def invalid_envelope(element)
        quarantine(element, nil, QuarantineReasons::INVALID_ENVELOPE,
                   "event is #{element.class}, not a JSON object")
      end

      def missing_event_type(element)
        quarantine(element, Envelope.event_id(element), QuarantineReasons::MISSING_EVENT_TYPE,
                   "type is #{element["type"].nil? ? "absent" : element["type"].class.to_s}")
      end

      # event_type stays nil on an unnameable envelope: the column is text, and writing
      # a coerced Integer into it would make the quarantine table lie about what arrived.
      def quarantine(element, github_event_id, error_code, error_message)
        Outcome.quarantined(
          event_type: nil, github_event_id: github_event_id, raw_payload: element,
          error_code: error_code, error_message: error_message,
          payload_fingerprint: PayloadFingerprint.fingerprint(element)
        )
      end

      def ignored(element, event_type)
        Outcome.ignored(event_type: event_type, github_event_id: Envelope.event_id(element),
                        raw_payload: element)
      end
    end
  end
end
