module Github
  module Enrichment
    class SearchResponse < Data.define(:ok, :items, :total_count, :incomplete_results,
                                       :error_message)
      def self.parse(body)
        document = body.is_a?(Hash) ? body : JSON.parse(body.to_s)
        return failure("Search response is not an object") unless document.is_a?(Hash)
        return failure("Search response items is not an array") unless document["items"].is_a?(Array)
        unless document["total_count"].is_a?(Integer) && [ true, false ].include?(document["incomplete_results"])
          return failure("Search response metadata is malformed")
        end

        new(ok: true, items: document["items"].freeze,
            total_count: document["total_count"],
            incomplete_results: document["incomplete_results"], error_message: nil)
      rescue JSON::ParserError => error
        failure(error.message)
      end

      def self.failure(message)
        new(ok: false, items: [].freeze, total_count: nil,
            incomplete_results: nil, error_message: message)
      end

      def ok? = ok
    end
  end
end
