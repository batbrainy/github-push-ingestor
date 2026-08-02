module Github
  module Enrichment
    # The repository half of Appendix G's useful-data completion contract: description,
    # primary language, owner GitHub id, fork and archived status, default branch, and
    # GitHub's creation time, alongside the complete raw item.
    #
    # `name` and `full_name` are deliberately absent, and this is the mapping §7 is most
    # explicit about: the envelope's repo.name is the qualified owner/repository form and
    # "is **not** silently equated with the enriched `name`". full_name and the final
    # segment it yields are envelope-owned by GithubRepository::IDENTITY_MERGE. Writing
    # the API's short name here would put two writers on one column.
    #
    # Unlike the pre-contract mapping, an absent or malformed owner no longer degrades to
    # NULL: #contract_error refuses any document without an integer owner id, because a
    # repository whose owner cannot be identified has not met the contract. Nullable
    # contract fields — description and language — stay nullable when GitHub returns null.
    module RepositoryDocument
      extend Parser

      class << self
        private

        def attributes_from(document)
          owner = document["owner"]

          {
            description: optional_string(document["description"]),
            language: optional_string(document["language"]),
            owner_github_id: owner.fetch("id"),
            owner_login: optional_string(owner["login"]),
            fork: document["fork"],
            archived: document["archived"],
            default_branch: document["default_branch"],
            github_created_at: Time.iso8601(document["created_at"]).utc
          }
        end

        def contract_error(document)
          owner = document["owner"]
          return malformed("owner.id must be an integer") unless owner.is_a?(Hash) && owner["id"].is_a?(Integer)
          return malformed("fork must be boolean") unless [ true, false ].include?(document["fork"])
          return malformed("archived must be boolean") unless [ true, false ].include?(document["archived"])
          return required_string(document["default_branch"], "default_branch") unless document["default_branch"].is_a?(String) && document["default_branch"].present?
          return malformed("description must be a string or null") unless document["description"].nil? || document["description"].is_a?(String)
          return malformed("language must be a string or null") unless document["language"].nil? || document["language"].is_a?(String)

          Time.iso8601(document["created_at"]) if document["created_at"].is_a?(String)
          return malformed("created_at must be ISO-8601") unless document["created_at"].is_a?(String)

          nil
        rescue ArgumentError
          malformed("created_at must be ISO-8601")
        end

        def malformed(message)
          Document.malformed(error_code: "invalid_contract_field", error_message: message)
        end
      end
    end
  end
end
