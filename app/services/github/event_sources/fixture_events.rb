module Github
  module EventSources
    # The offline source (IMPLEMENTATION_PLAN.md §6, §12): returns a deterministic
    # fixture location that Github::Transports::Fixture resolves entirely inside the
    # corpus. The live URL policy refuses the scheme outright, so a fixture location can
    # never leak into a live deployment.
    #
    # Its path and query match PublicEvents exactly, which is what lets one corpus entry
    # answer a request from either transport — the canonical request key omits scheme and
    # host precisely because Github::UrlPolicy has already proved them.
    class FixtureEvents < Base
      FIRST_PAGE_URL = "fixture://api.github.com/events?per_page=#{PublicEvents::PER_PAGE}".freeze

      def self.source_type = "github_fixture_events"

      def first_page_url = FIRST_PAGE_URL
    end
  end
end
