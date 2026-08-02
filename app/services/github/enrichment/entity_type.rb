module Github
  module Enrichment
    # The two enrichment classes, as one value each, so every other object in this
    # namespace takes an EntityType instead of branching on a symbol. §7 gives actors and
    # repositories an *identical* state machine over different columns, and this is where
    # the differences — the model, the parser, the TTL, the log key — are enumerated once.
    #
    # A memoised class method rather than a constant assigned in the class body: a
    # constant would pin the model class objects across a development reload, which is the
    # same reason Github::EventSources::Base memoises its registry.
    class EntityType < Data.define(:key, :model, :request_class, :search_request_class,
                                   :document, :log_key)
      class << self
        def all
          @all ||= [
            new(key: :actor, model: GithubActor, request_class: :actor,
                search_request_class: :actor_search,
                document: ActorDocument, log_key: :github_actor_id),
            new(key: :repository, model: GithubRepository, request_class: :repository,
                search_request_class: :repository_search,
                document: RepositoryDocument, log_key: :github_repository_id)
          ].freeze
        end

        # @param key [Symbol, String, Class] a key, or the model class itself — which is
        #   what the runners' #call(entity_class:) is handed.
        # @return [EntityType]
        def fetch(key)
          resolve(key) ||
            raise(ArgumentError, "unknown enrichment entity type #{key.inspect}")
        end

        # @return [EntityType, nil]
        def resolve(key)
          return key if key.is_a?(EntityType)

          all.find { |type| type.key == key.to_s.to_sym || type.model == key }
        end

        def keys = all.map(&:key)
      end

      def table_name = model.table_name

      # §10's per-class refresh TTL. Read through the configuration rather than stored on
      # this value, because the value is memoised per process while the configuration is
      # rebuilt by config/initializers/github.rb on every reload.
      def refresh_ttl_seconds(configuration = Github.configuration)
        configuration.refresh_ttl_seconds(request_class)
      end

      def to_log = key
    end
  end
end
