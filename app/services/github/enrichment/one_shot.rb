# Explicit, and load-bearing for the reason Github::Ingestion::OneShot gives: optparse is
# not required by Rails, and only running the binary catches its absence.
require "optparse"

module Github
  module Enrichment
    # The one-shot enrichment command — the operator surface for the staged batch
    # pipeline, holding the same contract Github::Ingestion::OneShot holds for polling.
    #
    # It returns its exit code and never calls exit; bin/enrich does, and that one line is
    # the only place in that file that ends a process. It owns the human text and the exit
    # code, while the batch and detail runners own the structured logs and every database
    # write — so neither can drift into the other's stream, which matters because §11 puts
    # both on stdout. The operator block is composed and written once, so a concurrent JSON
    # log line can never split it.
    #
    # **There is no source-lock wait and no Errors::SourceBusy path.** §8 step 1:
    # "Enrichment jobs skip this step — they take only the request gate." That absence is
    # the guarantee made visible. A held gate arrives as a FetchResult rather than an
    # exception, and is a deferral.
    #
    # **There is no pacing sleep here.** A pacing denial is reported and the command
    # stops — the always-on cycle waits pacing out; a one-shot reports the truth and
    # exits 0. The offline walkthrough sets SEARCH_PACING_SECONDS=0 to run both lanes
    # back to back.
    class OneShot
      Result = Data.define(:outcome, :exit_code, :tally)

      SUCCESS = 0
      FAILURE = 1
      REFUSED = 2

      REFUSING_ERRORS = [ Errors::ConfigurationError, Errors::FixtureMiss, Errors::FixtureCorpusError ].freeze

      STAGES = %w[ batch detail ].freeze

      DEFAULT_LIMIT = 1

      # Two consecutive idle claims end a lane — the same race guard the cycle uses.
      MAX_CONSECUTIVE_IDLE = CycleRunner::MAX_CONSECUTIVE_IDLE

      USAGE = <<~TEXT.freeze
        Usage: bin/enrich [options]

        Runs staged enrichment against the persisted actor and repository backlog, then
        prints what it did and the persisted state of the system. Search batches run
        first (up to SEARCH_BATCH_SIZE entities per request), then detail fallbacks from
        the bounded core allowance.

            --limit N        Attempt up to N requests (default #{DEFAULT_LIMIT}). Stops early
                             when nothing is eligible or a ledger defers the next request.
            --class CLASS    Restrict to actor or repository. It narrows selection and
                             bypasses nothing: both ledgers, pacing, the reserves, the
                             request gate and every global block still bind.
            --stage STAGE    Restrict to batch or detail.
            -h, --help       Print this message.

        There is deliberately no --force. §9 licenses --force against the poll cadence and
        the stored ETag; enrichment has no cadence, and every constraint it does have is
        one §10 requires to bind.

        Exit codes:
            0  every attempted request was decided or deferred — applied, terminal,
               nothing eligible, budget spent, pacing, gate held, or globally blocked
            1  at least one attempt failed and is scheduled to be retried
            2  refused to run — bad option, bad configuration, or a corpus gap
      TEXT

      def initialize(argv: [], output: $stdout, error_output: $stderr,
                     configuration: Github.configuration,
                     batch_runner: nil, detail_runner: nil, admission: nil,
                     batch_claim: nil, detail_claim: nil)
        @argv = argv
        @output = output
        @error_output = error_output
        @configuration = configuration
        @batch_runner = batch_runner || BatchRunner.new(configuration: configuration)
        @detail_runner = detail_runner || DetailRunner.new(configuration: configuration)
        @admission = admission || Admission.new(configuration: configuration)
        @batch_claim = batch_claim || BatchClaim.new(configuration: configuration)
        @detail_claim = detail_claim || DetailClaim.new(configuration: configuration)
      end

      # @return [Result]
      def call
        options = parse_options
        return Result.new(outcome: :usage_error, exit_code: REFUSED, tally: nil) if options.nil?
        return help if options.fetch(:help)

        enrich(limit: options.fetch(:limit), entity_class: options.fetch(:entity_class),
               stage: options.fetch(:stage))
      end

      private

      def enrich(limit:, entity_class:, stage:)
        @tally = Tally.empty
        @headlines = []
        @limit = limit
        lanes = lanes_for(entity_class)

        batch_lane(lanes) if stage.nil? || stage == "batch"
        detail_lane(lanes) if stage.nil? || stage == "detail"

        report(@tally) { @headlines.last || "Nothing to enrich — no eligible candidate" }
        undecided = @tally.batches_failed.positive? || @tally.details_retrying.positive?
        Result.new(outcome: undecided ? :retry_scheduled : :decided,
                   exit_code: undecided ? FAILURE : SUCCESS, tally: @tally)
      rescue *REFUSING_ERRORS => error
        @error_output.puts("#{humanize(error)}: #{error.message}")
        report
        Result.new(outcome: :refused, exit_code: REFUSED, tally: nil)
      end

      def batch_lane(lanes)
        schedule = CycleRunner::LaneSchedule.new(
          actor_weight: @configuration.actor_enrichment_weight,
          repository_weight: @configuration.repository_enrichment_weight
        )
        idle_streak = 0

        while @tally.requests < @limit
          verdict = @admission.search
          unless verdict.granted?
            @headlines << "Search deferred — #{verdict.reason}"
            return
          end

          choice = schedule.next_claimable(->(lane) {
            lanes.include?(lane) && @batch_claim.claimable?(EntityType.fetch(lane))
          })
          return if choice.nil?

          result = @batch_runner.call(entity_class: choice.first)
          @tally = @tally.record_batch(result)
          case result.status
          when "idle"
            idle_streak += 1
            return if idle_streak >= MAX_CONSECUTIVE_IDLE
          when "deferred"
            @headlines << "Search batch deferred — #{result.deferral_reason}"
            return
          else
            idle_streak = 0
            @headlines << batch_headline(result)
          end
        end
      end

      def detail_lane(lanes)
        schedule = CycleRunner::LaneSchedule.new(
          actor_weight: @configuration.actor_enrichment_weight,
          repository_weight: @configuration.repository_enrichment_weight
        )
        idle_streak = 0

        while @tally.requests < @limit
          verdict = @admission.detail
          unless verdict.granted?
            @headlines << "Detail fallback deferred — #{verdict.reason}"
            return
          end

          choice = schedule.next_claimable(->(lane) {
            lanes.include?(lane) && @detail_claim.claimable?(EntityType.fetch(lane))
          })
          return if choice.nil?

          lane, borrowed = choice
          result = @detail_runner.call(entity_class: lane, borrow: borrowed)
          @tally = @tally.record_detail(result)
          case result.status
          when "idle"
            idle_streak += 1
            return if idle_streak >= MAX_CONSECUTIVE_IDLE
          when "deferred"
            @headlines << "Detail fallback deferred — #{result.reason}"
            return
          else
            idle_streak = 0
            @headlines << detail_headline(result)
          end
        end
      end

      def lanes_for(entity_class)
        return EntityType.keys if entity_class.nil?

        [ EntityType.resolve(entity_class).key ]
      end

      def batch_headline(result)
        if result.status == "completed"
          "Search batch #{result.entity_type} ##{result.batch_id} — requested #{result.requested_count}, " \
            "valid #{result.valid_count}, fallback #{result.fallback_count}"
        else
          "Search batch #{result.entity_type} ##{result.batch_id} failed — #{result.deferral_reason}; retry scheduled"
        end
      end

      def detail_headline(result)
        case result.status
        when "completed" then "Detail #{result.entity_type} #{result.github_id} — complete"
        when "terminal" then "Detail #{result.entity_type} #{result.github_id} — terminal: #{result.reason}"
        when "lease_lost" then "Detail #{result.entity_type} #{result.github_id} — claimed by another worker"
        else "Detail #{result.entity_type} #{result.github_id} — retry scheduled: #{result.reason}"
        end
      end

      # Printed on every path that has a database, including the deferred and refused ones,
      # and composed as one string so a concurrent log line cannot split it. Both snapshots
      # are captured after the runners return, so they reflect this invocation's own writes.
      def report(tally = nil)
        enrichment = Summary.capture
        state = Ingestion::StateSummary.capture
        headline = block_given? ? yield : nil

        @output.puts([ headline, tally&.to_s, enrichment.to_s, state.to_s ].compact.join("\n\n"))
      rescue StandardError => error
        # A summary that cannot be read must not mask the outcome that was already decided.
        @error_output.puts("State summary unavailable: #{error.class.name}")
      end

      def help
        @output.puts(USAGE)
        Result.new(outcome: :help, exit_code: SUCCESS, tally: nil)
      end

      # @return [Hash, nil] nil when the invocation itself was wrong
      def parse_options
        options = { limit: DEFAULT_LIMIT, entity_class: nil, stage: nil, help: false }

        parser = OptionParser.new do |parser|
          parser.on("--limit N", Integer) { |value| options[:limit] = value }
          parser.on("--class CLASS") { |value| options[:entity_class] = value }
          parser.on("--stage STAGE") { |value| options[:stage] = value }
          parser.on("-h", "--help") { options[:help] = true }
        end

        remaining = parser.parse(@argv.dup)
        return usage_error("unexpected argument #{remaining.first.inspect}") unless remaining.empty?
        return usage_error("--limit must be greater than 0, got #{options[:limit]}") unless options[:limit].positive?
        unless options[:stage].nil? || STAGES.include?(options[:stage])
          return usage_error("--stage must be one of #{STAGES.join(", ")}, got #{options[:stage].inspect}")
        end
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
