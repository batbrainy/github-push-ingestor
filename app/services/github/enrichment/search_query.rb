module Github
  module Enrichment
    # Builds the one Search URL a batch claim will fetch: repeated exact qualifiers
    # (`user:` / `repo:`) joined by spaces — never `OR`, which the live probe showed
    # answers HTTP 422 (issue #45). per_page equals the batch size so the requested
    # and returned sets are comparable one-to-one.
    #
    # Mode-aware for the same reason Github::EventSources splits PublicEvents from
    # FixtureEvents: these are application-origin URLs, and Github::UrlPolicy accepts
    # only the fixture scheme in fixture mode — fail closed, never a live fallback.
    class SearchQuery
      ENDPOINT_PATHS = {
        actor: "/search/users",
        repository: "/search/repositories"
      }.freeze
      ORIGINS = {
        live: "https://api.github.com",
        fixture: "fixture://api.github.com"
      }.freeze
      QUALIFIERS = { actor: "user", repository: "repo" }.freeze

      def self.build(entity_type, identifiers, mode: Github.configuration.mode)
        identifiers = identifiers.map(&:to_s)
        raise ArgumentError, "Search batch cannot be empty" if identifiers.empty?

        origin = ORIGINS.fetch(mode.to_sym) do
          raise ArgumentError, "unknown mode #{mode.inspect}"
        end
        query = identifiers.map { |identifier| "#{QUALIFIERS.fetch(entity_type.key)}:#{identifier}" }.join(" ")
        "#{origin}#{ENDPOINT_PATHS.fetch(entity_type.key)}?#{URI.encode_www_form(q: query, per_page: identifiers.length)}"
      end
    end
  end
end
