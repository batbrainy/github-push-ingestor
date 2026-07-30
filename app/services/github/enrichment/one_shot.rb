# Explicit, and load-bearing for the reason Github::Ingestion::OneShot gives: optparse is
# not required by Rails, and only running the binary catches its absence.
require "optparse"

module Github
  module Enrichment
    # The one-shot enrichment command — the operator surface for §13's PR 7, and the same
    # contract Github::Ingestion::OneShot holds for polling.
    #
    # It returns its exit code and never calls exit; bin/enrich does, and that one line is
    # the only place in that file that ends a process. It owns the human text and the exit
    # code, while Github::EnrichmentRunner owns the structured logs and every database
    # write — so neither can drift into the other's stream, which matters because §11 puts
    # both on stdout. The operator block is composed and written once, so a concurrent JSON
    # log line can never split it.
    #
    # **There is no source-lock wait and no Errors::SourceBusy path.** §8 step 1:
    # "Enrichment jobs skip this step — they take only the request gate." That absence is
    # the guarantee made visible, and a spec asserts the runner is called without one. A
    # held gate arrives as a FetchResult rather than an exception, and is a deferral.
    class OneShot
      Result = Data.define(:outcome, :exit_code, :tally)

      SUCCESS = 0
      FAILURE = 1
      REFUSED = 2

      REFUSING_ERRORS = [ Errors::ConfigurationError, Errors::FixtureMiss, Errors::FixtureCorpusError ].freeze

      # An entity that is provably gone is a *decided*, durable outcome — the command did
      # exactly its job, and §10 is explicit that a 404 on one enrichment target is not a
      # failure of anything else. Only an undecided attempt is a failed one. Without this
      # line a reviewer running the deterministic fixture scenario would get exit 1 for
      # ghostuser, which is correct behaviour reported as breakage.
      DECIDED_STATUSES = %w[ complete permanent_failure ].freeze

      # Continuing past these would spin: nothing became eligible, or the next cycle would
      # be refused identically. A failed entity is *not* among them — §16 requires that
      # malformed data "does not terminate the batch", and the same reasoning applies to an
      # entity that 404s halfway through a --limit.
      STOPPING_STATUSES = %w[ idle deferred ].freeze

      DEFAULT_LIMIT = 1

      USAGE = <<~TEXT.freeze
        Usage: bin/enrich [options]

        Runs enrichment cycles against the persisted actor and repository backlog, then
        prints what it did and the persisted state of the system. Each cycle enriches at
        most one entity, chosen by the fairness policy in IMPLEMENTATION_PLAN.md §10.

            --limit N        Run up to N cycles (default #{DEFAULT_LIMIT}). Stops early when
                             nothing is eligible or the budget defers the next cycle.
            --class CLASS    Restrict to actor or repository. It narrows selection and
                             bypasses nothing: the enrichment allowance, the per-class
                             fairness share, the reserve, the request gate and every
                             global block still bind.
            -h, --help       Print this message.

        There is deliberately no --force. §9 licenses --force against the poll cadence and
        the stored ETag; enrichment has no cadence, and every constraint it does have is
        one §10 requires to bind.

        Exit codes:
            0  enriched, decided, or deferred — nothing eligible, budget spent, gate held,
               rate limited, globally blocked, or the entity is provably gone
            1  an attempt failed and is scheduled to be retried
            2  refused to run — bad option, bad configuration, or a corpus gap
      TEXT

      def initialize(argv: [], output: $stdout, error_output: $stderr,
                     runner: EnrichmentRunner.new)
        @argv = argv
        @output = output
        @error_output = error_output
        @runner = runner
      end

      # @return [Result]
      def call
        options = parse_options
        return Result.new(outcome: :usage_error, exit_code: REFUSED, tally: nil) if options.nil?
        return help if options.fetch(:help)

        enrich(limit: options.fetch(:limit), entity_class: options.fetch(:entity_class))
      end

      private

      def enrich(limit:, entity_class:)
        tally = Tally.empty
        last = nil

        limit.times do
          last = @runner.call(entity_class: entity_class)
          tally = tally.record(last)
          break if STOPPING_STATUSES.include?(last.status)
        end

        report(tally) { headline(last) }
        Result.new(outcome: last.status.to_sym, exit_code: exit_code_for(last), tally: tally)
      rescue *REFUSING_ERRORS => error
        @error_output.puts("#{humanize(error)}: #{error.message}")
        report
        Result.new(outcome: :refused, exit_code: REFUSED, tally: nil)
      end

      # Only an undecided attempt fails the command. A permanent_failure is a decided
      # outcome; a retryable_failure is the one case where the work is genuinely unfinished
      # and rerunning later is the right response.
      def exit_code_for(result)
        return SUCCESS unless result.failed?

        DECIDED_STATUSES.include?(result.enrichment_status) ? SUCCESS : FAILURE
      end

      # Printed on every path that has a database, including the deferred and refused ones,
      # and composed as one string so a concurrent log line cannot split it. Both snapshots
      # are captured after the runner returns, so they reflect this invocation's own writes.
      def report(tally = nil)
        enrichment = Summary.capture
        state = Ingestion::StateSummary.capture
        headline = block_given? ? yield : nil

        @output.puts([ headline, tally&.to_s, enrichment.to_s, state.to_s ].compact.join("\n\n"))
      rescue StandardError => error
        # A summary that cannot be read must not mask the outcome that was already decided.
        @error_output.puts("State summary unavailable: #{error.class.name}")
      end

      def headline(result)
        case result.status
        when "enriched" then "Enriched #{entity_label(result)} — complete"
        when "failed" then failure_line(result)
        when "deferred" then "Enrichment deferred — #{result.deferral_reason}"
        when "lease_lost" then "Enrichment discarded — #{entity_label(result)} was claimed by another worker"
        else "Nothing to enrich — no eligible candidate"
        end
      end

      def failure_line(result)
        scheduled = result.next_retry_at ? " — retry after #{Ingestion::Report.timestamp(result.next_retry_at)}" : ""

        "#{entity_label(result).capitalize} #{result.enrichment_status}#{scheduled}: #{result.last_error}"
      end

      def entity_label(result)
        "#{result.entity_type} #{result.github_id}"
      end

      def help
        @output.puts(USAGE)
        Result.new(outcome: :help, exit_code: SUCCESS, tally: nil)
      end

      # @return [Hash, nil] nil when the invocation itself was wrong
      def parse_options
        options = { limit: DEFAULT_LIMIT, entity_class: nil, help: false }

        parser = OptionParser.new do |parser|
          parser.on("--limit N", Integer) { |value| options[:limit] = value }
          parser.on("--class CLASS") { |value| options[:entity_class] = value }
          parser.on("-h", "--help") { options[:help] = true }
        end

        remaining = parser.parse(@argv.dup)
        return usage_error("unexpected argument #{remaining.first.inspect}") unless remaining.empty?
        return usage_error("--limit must be greater than 0, got #{options[:limit]}") unless options[:limit].positive?
        return options if options[:entity_class].nil? || EntityType.resolve(options[:entity_class])

        usage_error("--class must be one of #{EntityType.keys.join(", ")}, got #{options[:entity_class].inspect}")
      rescue OptionParser::ParseError => error
        usage_error(error.message)
      end

      def usage_error(message)
        @error_output.puts("bin/enrich: #{message}")
        @error_output.puts(USAGE)
        nil
      end

      def humanize(error)
        error.is_a?(Errors::ConfigurationError) ? "Configuration error" : "Fixture corpus error"
      end
    end
  end
end
