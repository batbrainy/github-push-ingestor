module Github
  module Enrichment
    # §7's repository mapping: "(enrichment populates description, language,
    # owner_github_id, raw_payload)".
    #
    # `name` and `full_name` are deliberately absent, and this is the mapping §7 is most
    # explicit about: the envelope's repo.name is the qualified owner/repository form and
    # "is **not** silently equated with the enriched `name`". full_name and the final
    # segment it yields are envelope-owned by GithubRepository::IDENTITY_MERGE. Writing
    # the API's short name here would put two writers on one column.
    #
    # owner_github_id is nullable with no foreign key, so an absent or malformed owner
    # object degrades to NULL rather than failing the document.
    module RepositoryDocument
      extend Parser

      class << self
        private

        def attributes_from(document)
          owner = document["owner"]

          {
            description: optional_string(document["description"]),
            language: optional_string(document["language"]),
            owner_github_id: owner.is_a?(Hash) ? optional_integer(owner["id"]) : nil
          }
        end
      end
    end
  end
end
