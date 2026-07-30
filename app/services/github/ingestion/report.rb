module Github
  module Ingestion
    # The one-shot command's stdout formatting (IMPLEMENTATION_PLAN.md §9).
    #
    # §9 prints two blocks — the end-of-run counters and the state summary — and shows
    # them column-aligned:
    #
    #   Latest successful run:            2026-07-29T14:00:12Z (run_id …)
    #   Persisted push events:            1,284
    #   Pending repository enrichments:   407
    #   Budget remaining (core):          31 (window resets 14:32:00Z)
    #
    # All four of those labels put their value at the same column, and 34 is the width
    # that reproduces every one of them. Sharing the constant is the point: the two blocks
    # are produced by different objects, and a reviewer reads them as one report.
    module Report
      LABEL_WIDTH = 34

      module_function

      def line(label, value)
        "#{"#{label}:".ljust(LABEL_WIDTH)}#{value}"
      end

      # §9 shows "1,284". ActiveSupport::NumberHelper rather than ActionView's
      # number_with_delimiter, which is not loaded in an API-only application.
      def count(value)
        ActiveSupport::NumberHelper.number_to_delimited(value)
      end

      # One timestamp format everywhere, always UTC and always suffixed, so a log line
      # and a printed line are directly comparable and neither is ambiguous at midnight.
      # §9's sample abbreviates the budget reset to a time of day; this deliberately does
      # not.
      def timestamp(value)
        value&.utc&.iso8601
      end
    end
  end
end
