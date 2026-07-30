module Github
  module Enrichment
    # §7's actor mapping, which is one line long: "(enrichment populates name and
    # raw_payload)".
    #
    # login, display_login, api_url and avatar_url are deliberately absent. They are
    # envelope-owned — GithubActor::IDENTITY_MERGE is their only writer, and §7 keeps the
    # envelope shape and the enriched document shape explicitly distinct. The accepted
    # consequence is that a renamed login stays at the last envelope value until the next
    # event refreshes it; the enriched truth is in raw_payload either way.
    module ActorDocument
      extend Parser

      class << self
        private

        def attributes_from(document)
          { name: optional_string(document["name"]) }
        end
      end
    end
  end
end
