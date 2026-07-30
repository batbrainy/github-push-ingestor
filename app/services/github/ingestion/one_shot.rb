module Github
  module Ingestion
    # The one-shot ingestion command (IMPLEMENTATION_PLAN.md §9).
    #
    # `docker compose run --rm ingest` runs while the poller may be live, so §9 gives it a
    # contention contract rather than leaving the interaction to chance:
    #
    #   * retry the source lock for up to SOURCE_LOCK_WAIT_SECONDS (30);
    #   * if it is still unavailable, print "source busy — poller cycle in progress" plus
    #     the state summary, and exit 0;
    #   * send every request through the same gate and ledger as the poller and worker;
    #   * always prove system state on stdout, "even when deferred or busy".
    #
    # It returns its exit code and never calls exit — bin/ingest does, and that one line is
    # the only place in the application that ends a process. Returning the code is what makes
    # the whole contract a plain unit test rather than a shelled-out one.
    #
    # It owns the human text and the exit code; Github::IngestionRunner owns the structured
    # logs and every database write. Neither can drift into the other's stream, which matters
    # because §11 puts both on stdout: the operator block is composed and written once, so it
    # can never interleave with a JSON log line.
    class OneShot
      Result = Data.define(:outcome, :exit_code)

      # §9 pins 0 for a busy source. Every other deferral shares it for the same reason §10
      # gives — a budget denial, a held gate and a rate-limit response mean the request never
      # happened, not that anything failed, and a reviewer's command must not look broken
      # because the poller happened to hold the lock.
      SUCCESS = 0
      # The attempt happened and did not produce usable events.
      FAILURE = 1
      # Refused to run at all: a bad option, a configuration the process must not run with,
      # or a corpus gap. All mean "fix the invocation", and all recur identically until it is.
      REFUSED = 2

      REFUSING_ERRORS = [ Errors::ConfigurationError, Errors::FixtureMiss, Errors::FixtureCorpusError ].freeze

      BUSY_MESSAGE = "source busy — poller cycle in progress".freeze

      USAGE = <<~TEXT.freeze
        Usage: bin/ingest [options]

        Runs one ingestion cycle against the configured event source, then prints what it
        did and the persisted state of the system.

            --force      Ignore the configured poll cadence and the stored ETag.
                         No effect yet: cadence gating and ETag reuse land with the
                         poller (IMPLEMENTATION_PLAN.md §13, PR 6).
            -h, --help   Print this message.

        Exit codes:
            0  ran, or deferred — source busy, budget spent, gate held, rate limited
            1  the attempt failed
            2  refused to run — bad option, bad configuration, or a corpus gap
      TEXT

      def initialize(argv: [], output: $stdout, error_output: $stderr,
                     configuration: Github.configuration, runner: IngestionRunner.new,
                     provisioner: SourceProvisioner)
        @argv = argv
        @output = output
        @error_output = error_output
        @configuration = configuration
        @runner = runner
        @provisioner = provisioner
      end

      # @return [Result]
      def call
        options = parse_options
        return Result.new(outcome: :usage_error, exit_code: REFUSED) if options.nil?
        return help if options.fetch(:help)

        ingest(force: options.fetch(:force))
      end

      private

      def ingest(force:)
        event_source = @provisioner.ensure!
        result = @runner.call(event_source: event_source,
                              wait_seconds: @configuration.source_lock_wait_seconds, force: force)

        report(outcome_line(result), result.tally)
        Result.new(outcome: result.status.to_sym, exit_code: result.failed? ? FAILURE : SUCCESS)
      rescue Errors::SourceBusy
        # §9's wording, verbatim. No run row exists — the runner opens one inside the lock —
        # so there is no tally to print, only the state that already existed.
        report(BUSY_MESSAGE)
        Result.new(outcome: :busy, exit_code: SUCCESS)
      rescue *REFUSING_ERRORS => error
        @error_output.puts("#{humanize(error)}: #{error.message}")
        report
        Result.new(outcome: :refused, exit_code: REFUSED)
      end

      # §9's summary is printed on every path that has a database, including the failing and
      # deferred ones — captured *after* the lock is released, so it reflects the run's own
      # writes. Composed and written as one string so a concurrent log line cannot split it.
      def report(headline = nil, tally = nil)
        summary = StateSummary.capture

        blocks = [ headline, tally&.to_s, summary.to_s ].compact

        @output.puts(blocks.join("\n\n"))
      rescue StandardError => error
        # A summary that cannot be read must not mask the outcome that was already decided.
        @error_output.puts("State summary unavailable: #{error.class.name}")
      end

      def outcome_line(result)
        case result.status
        when "completed" then "Ingestion run #{result.run_id} completed"
        when "not_modified" then "Ingestion run #{result.run_id} completed — GitHub reported no changes (304)"
        when "deferred" then deferred_line(result)
        else "Ingestion run #{result.run_id} failed: #{result.last_error}"
        end
      end

      # §9's line is "Ingestion deferred until T", where T comes from effective_poll_time.
      # PR 5 has no cadence to defer against, so the instant it can honestly name is the one
      # the ledger already knows: the window reset. When there is none — a held gate has no
      # instant at all — the reason stands on its own.
      def deferred_line(result)
        reset_at = Report.timestamp(GithubApiBudget.where(id: GithubApiBudget::SINGLETON_ID).pick(:reset_at))
        until_clause = reset_at ? " until #{reset_at}" : ""

        "Ingestion deferred#{until_clause} — #{result.deferral_reason}"
      end

      def help
        @output.puts(USAGE)
        Result.new(outcome: :help, exit_code: SUCCESS)
      end

      # @return [Hash, nil] nil when the invocation itself was wrong
      def parse_options
        options = { force: false, help: false }

        parser = OptionParser.new do |parser|
          parser.on("--force") { options[:force] = true }
          parser.on("-h", "--help") { options[:help] = true }
        end

        remaining = parser.parse(@argv.dup)
        return options if remaining.empty?

        usage_error("unexpected argument #{remaining.first.inspect}")
      rescue OptionParser::ParseError => error
        usage_error(error.message)
      end

      def usage_error(message)
        @error_output.puts("bin/ingest: #{message}")
        @error_output.puts(USAGE)
        nil
      end

      def humanize(error)
        error.is_a?(Errors::ConfigurationError) ? "Configuration error" : "Fixture corpus error"
      end
    end
  end
end
