module Github
  # RFC 8288 Link-header parsing, for the pagination §9 mandates: "follow the Link
  # response header for subsequent pages (GitHub's documented recommendation) rather than
  # constructing page URLs."
  #
  # Constructing them would mean this application deciding what page 2 is. Following the
  # header means GitHub decides, which is the whole point — and it is why the target is
  # returned verbatim here and validated somewhere else. Github::EventSources::Base marks
  # a Link target `origin: :payload`, so Github::UrlPolicy.validate_payload_url! re-parses
  # it under the full live policy (https, host exactly api.github.com, no userinfo, no
  # port, no IP literal) before any socket opens. This module trusts nothing and proves
  # nothing; it only reads.
  #
  # It never raises. A Link header this cannot read means "there is no next page", which
  # ends the walk cleanly with every page so far already persisted. Raising would turn a
  # header GitHub is free to change into a failed run.
  module LinkHeader
    # One link-value: a bracketed target, then its parameters. The parameter run tolerates
    # quoted values containing commas and semicolons, which is why this is a scanner over
    # the whole header rather than a split on ",".
    LINK_VALUE = /<([^>]*)>((?:\s*;\s*[^;,"]*(?:"[^"]*")?)*)/
    # RFC 8288 permits both `rel="next"` and the bare `rel=next`.
    PARAMETER = /;\s*([^\s=;]+)\s*=\s*(?:"([^"]*)"|([^;,\s]*))/

    NEXT = "next".freeze

    module_function

    # @param value [String, nil] the raw Link header
    # @return [Hash{String => String}] relation type (downcased) => target, verbatim.
    #   The first occurrence of a relation wins; a rel carrying several space-separated
    #   types registers the target under each. Unknown parameters are ignored.
    def parse(value)
      return {} if value.nil? || value.to_s.strip.empty?

      value.to_s.scan(LINK_VALUE).each_with_object({}) do |(target, parameters), links|
        next if target.to_s.strip.empty?

        relations(parameters).each { |relation| links[relation] ||= target }
      end
    end

    # @return [String, nil] nil for an absent, unreadable, or next-less header — all of
    #   which mean the same thing to the caller.
    def next_url(value)
      parse(value)[NEXT]
    end

    # Only rel is read. GitHub's /events header also carries rel="last", and page one's
    # points at the final page — so an implementation that took the first bracketed URL,
    # or preferred "last", would skip every page in between.
    def relations(parameters)
      parameters.to_s.scan(PARAMETER).filter_map do |name, quoted, bare|
        next unless name.casecmp?("rel")

        (quoted || bare).to_s.downcase.split
      end.flatten
    end
    private_class_method :relations
  end
end
