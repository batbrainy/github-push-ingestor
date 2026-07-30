module Github
  module Transports
    # What a transport returns: a status, lowercased headers, and the body exactly as
    # received. Deliberately dumb — classification is Github::ResponseClassifier's job
    # and parsing is the event source's, so a transport is only ever asked whether it
    # can speak the protocol.
    #
    # Header names are downcased here, at the one place both transports pass through, so
    # no caller ever has to guess at GitHub's casing.
    class Response < Data.define(:status, :headers, :body, :url, :duration_ms)
      def self.normalize(headers)
        (headers || {}).to_h { |name, value| [ name.to_s.downcase, value.to_s ] }.freeze
      end

      def header(name)
        headers[name.to_s.downcase]
      end
    end
  end
end
