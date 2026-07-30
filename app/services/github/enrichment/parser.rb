module Github
  module Enrichment
    # What ActorDocument and RepositoryDocument share: decoding the body, proving it
    # describes the entity that was asked for, and one tolerance rule. Both `extend` it,
    # so #parse is a public singleton method on each and the helpers below are private
    # ones — the same shape Github::UrlPolicy uses.
    #
    # **Identity fields are strict; everything else degrades to NULL.** That is §7's
    # tolerant-parser doctrine applied here. Refusing a whole document because `language`
    # arrived as a number would throw away the `description` that arrived correctly, and a
    # malformed verdict is destructive: it writes permanent_failure and the entity is
    # never fetched again. The identity fields get no such tolerance, because a document
    # that cannot prove which row it belongs to has nothing safe to write anywhere.
    #
    # An includer supplies one private method, `attributes_from(document)`, returning the
    # columns §7 assigns to enrichment for that class.
    module Parser
      # @param body [String, Hash, nil] the response body, decoded or not
      # @param github_id [Integer] the row this document is supposed to describe
      # @return [Github::Enrichment::Document]
      def parse(body, github_id:)
        document = decode(body)
        return document if document.is_a?(Document)

        identity = document["id"]
        unless identity.is_a?(Integer)
          return Document.malformed(error_code: "missing_identity",
                                    error_message: "document carries no integer id")
        end
        return Document.identity_mismatch(expected: github_id, actual: identity) unless identity == github_id

        Document.ok(attributes: attributes_from(document).merge(raw_payload: document))
      end

      private

      # @return [Hash, Github::Enrichment::Document] the decoded object, or the malformed
      #   verdict that stops the parse.
      def decode(body)
        return body if body.is_a?(Hash)

        if body.blank?
          return Document.malformed(error_code: "unparsable_document",
                                    error_message: "response body was empty")
        end

        parsed = JSON.parse(body.to_s)
        return parsed if parsed.is_a?(Hash)

        Document.malformed(error_code: "not_an_object",
                           error_message: "expected a JSON object, got #{parsed.class}")
      rescue JSON::ParserError => error
        Document.malformed(error_code: "unparsable_document", error_message: error.message)
      end

      # Non-String and blank both become nil, so a column never stores "" or a number
      # that happened to arrive where prose was expected. Mirrors
      # Github::Events::PushEventProcessor#optional_string.
      def optional_string(value)
        return nil unless value.is_a?(String)

        value.presence
      end

      def optional_integer(value)
        value if value.is_a?(Integer)
      end
    end
  end
end
