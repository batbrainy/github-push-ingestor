module Inspection
  # Every error the inspection endpoints raise, in one file under one namespace — the
  # shape Github::Errors already establishes, and the reason Zeitwerk needs no help
  # mapping it.
  module Errors
    Error = Class.new(StandardError)

    # A query parameter this endpoint understands but cannot use, or one it does not
    # understand at all. ApplicationController maps it to 400.
    #
    # The offending parameter is a reader rather than only a phrase inside the message, so
    # the response can name it in a machine-readable key and a spec can assert on that
    # instead of on prose.
    class InvalidParameter < Error
      attr_reader :parameter

      def initialize(parameter, detail)
        @parameter = parameter.to_s
        super("#{@parameter} #{detail}")
      end
    end
  end
end
