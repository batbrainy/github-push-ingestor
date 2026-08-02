module Github
  module Enrichment
    # The useful-data actor contract intentionally excludes full-profile fields. Search
    # and detail responses contribute account type plus the complete raw item.
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
          { account_type: document["type"] }
        end

        def contract_error(document)
          required_string(document["type"], "type") unless document["type"].is_a?(String) && document["type"].present?
        end
      end
    end
  end
end
