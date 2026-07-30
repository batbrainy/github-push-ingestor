module Github
  module EventSources
    # The required delivered source (IMPLEMENTATION_PLAN.md §6):
    #
    #   GET https://api.github.com/events
    #
    # per_page=100 is part of the canonical first-page URL rather than something a
    # caller adds, because §9 scopes the persisted ETag to exactly this URL with its
    # stable query parameters — a URL that varied between polls would never match.
    class PublicEvents < Base
      PER_PAGE = 100
      FIRST_PAGE_URL = "https://api.github.com/events?per_page=#{PER_PAGE}".freeze

      def self.source_type = "github_public_events"

      def first_page_url = FIRST_PAGE_URL
    end
  end
end
