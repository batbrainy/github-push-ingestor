module Github
  # Loads the static corpus under fixtures/github/ (IMPLEMENTATION_PLAN.md §12) and
  # answers a canonical request key with an ordered list of scripted responses.
  #
  # It exists so the fixture transport does no file I/O and no path arithmetic of its
  # own: body paths are read from the manifest and never derived from a URL, which is
  # what makes `fixture://api.github.com/../../etc/passwd` a miss rather than a file
  # read. Every resolved path is additionally proved to sit inside bodies/, so even a
  # hostile manifest cannot escape.
  #
  # Bodies are read eagerly at load. The corpus is small, and a missing or unparseable
  # body should fail when the corpus is loaded rather than on the one poll that happens
  # to need it.
  class FixtureCorpus
    MANIFEST_FILENAME = "manifest.json"
    BODIES_DIRNAME = "bodies"
    SUPPORTED_VERSION = 1
    DEFAULT_SCENARIO = "default"

    ScriptedResponse = Data.define(:status, :headers, :body)

    class << self
      def load(root: Github.configuration.fixture_root, scenario: Github.configuration.fixture_scenario)
        cache[[ root.to_s, scenario.to_s ]] ||= new(root: root, scenario: scenario)
      end

      def reset!
        @cache = nil
      end

      # The canonical request key: the path, then query parameters sorted by name.
      # Scheme and host are omitted because UrlPolicy has already proved them, so one
      # manifest entry answers a request from either transport.
      def key_for(validated_url)
        canonical_key(validated_url.path, validated_url.query)
      end

      def canonical_key(path, query)
        path = "/" if path.nil? || path.empty?
        pairs = URI.decode_www_form(query.to_s).sort

        pairs.empty? ? path : "#{path}?#{URI.encode_www_form(pairs)}"
      end

      private

      def cache
        @cache ||= {}
      end
    end

    def initialize(root:, scenario: DEFAULT_SCENARIO)
      @root = Pathname.new(root)
      @scenario = scenario.to_s
      @manifest = read_manifest
      @responses = build_responses
    end

    attr_reader :root, :scenario, :responses

    # @return [Array<ScriptedResponse>, nil] nil when the corpus does not define the key
    def responses_for(key)
      responses[key]
    end

    def key_for(validated_url)
      self.class.key_for(validated_url)
    end

    def keys
      responses.keys
    end

    def scenario_names
      @manifest.fetch("scenarios").keys
    end

    private

    def read_manifest
      path = root.join(MANIFEST_FILENAME)
      raise Errors::FixtureCorpusError, "no fixture manifest at #{path}" unless path.file?

      # JSON, not YAML: a corpus file must not be able to instantiate Ruby objects.
      manifest = JSON.parse(path.read)

      unless manifest["version"] == SUPPORTED_VERSION
        raise Errors::FixtureCorpusError,
              "fixture manifest version #{manifest["version"].inspect} is not supported"
      end

      manifest
    rescue JSON::ParserError => e
      raise Errors::FixtureCorpusError, "fixture manifest at #{root} is not valid JSON: #{e.message}"
    end

    # `inherit` resolves exactly one level: a scenario's behaviour has to be readable in
    # one place, and a chain of overrides is not.
    def build_responses
      scenarios = @manifest.fetch("scenarios")
      selected = scenarios[scenario]
      raise Errors::FixtureCorpusError, "the corpus defines no #{scenario.inspect} scenario" if selected.nil?

      inherited = selected["inherit"]
      base = inherited ? scenarios.fetch(inherited) { raise_unknown_parent(inherited) }.fetch("responses") : {}

      normalize(base.merge(selected.fetch("responses")))
    end

    def raise_unknown_parent(inherited)
      raise Errors::FixtureCorpusError, "scenario #{scenario.inspect} inherits from unknown #{inherited.inspect}"
    end

    def normalize(responses)
      responses.to_h do |key, scripted|
        path, _, query = key.partition("?")
        [ self.class.canonical_key(path, query), scripted.map { |entry| build_response(entry) } ]
      end.freeze
    end

    def build_response(entry)
      ScriptedResponse.new(
        status: Integer(entry.fetch("status")),
        headers: default_headers.merge(entry.fetch("headers", {})).transform_keys(&:downcase).freeze,
        body: entry["body"] ? read_body(entry["body"]) : ""
      )
    end

    def default_headers
      @default_headers ||= @manifest.fetch("default_headers", {}).transform_keys(&:downcase).freeze
    end

    def read_body(relative_path)
      bodies_root = root.join(BODIES_DIRNAME)
      path = Pathname.new(File.expand_path(relative_path, bodies_root))

      # Belt and braces: the manifest is trusted input, but a body path that escaped
      # bodies/ would turn the corpus into an arbitrary file reader, so it is proved
      # rather than assumed.
      unless path.to_s.start_with?("#{bodies_root}/")
        raise Errors::FixtureCorpusError, "fixture body #{relative_path.inspect} escapes #{bodies_root}"
      end
      raise Errors::FixtureCorpusError, "no fixture body at #{path}" unless path.file?

      path.read.freeze
    end
  end
end
