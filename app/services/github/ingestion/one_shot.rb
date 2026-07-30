# Explicit, and load-bearing: optparse is not required by Rails. The test suite happens to
# have it loaded through another gem, so nothing in RSpec catches its absence — only running
# bin/ingest does, which is why CI now does exactly that.
require "optparse"

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

      # §9's instant comes from effective_poll_time, which the runner computes and puts on
      # its Result — so this class names T for every reason but two.
      #
      # A held gate has no instant at all: it clears when whoever holds it lets go, and
      # naming a time would be a confident wrong answer.
      NO_INSTANT_REASONS = %w[ gate_unavailable ].freeze
      # :reserve_reached is a ledger denial reflecting GitHub's own `remaining`, not a term
      # of §9's formula — so effective_poll_time can sit in the past while the ledger still
      # refuses, and the window reset is the honest instant. Making the reserve a
      # scheduling component was the tempting simplification and is wrong: a co-tenant's
      # window rolling can clear it at any moment, so it has no stable instant to schedule
      # against.
      RESET_BACKED_REASONS = %w[ reserve_reached ].freeze

      BUSY_MESSAGE = "source busy — poller cycle in progress".freeze

      USAGE = <<~TEXT.freeze
        Usage: bin/ingest [options]

        Runs one ingestion cycle against the configured event source, then prints what it
        did and the persisted state of the system.

            --force      Ignore the configured poll cadence and omit the stored ETag.
                         Nothing else: it does not bypass the source lock, GitHub's
                         X-Poll-Interval floor, this source's own backoff, a global
                         block, the poll class allowance, or the reserve
                         (IMPLEMENTATION_PLAN.md §9).
            -h, --help   Print this message.

        Exit codes:
            0  ran, or deferred — not yet due, source busy, budget spent, gate held,
               rate limited, globally blocked
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

        # No counters on a deferral. Nothing was fetched, so seven zeroes would suggest a
        # run that produced nothing rather than a run that never happened — and under a
        # five-minute cadence a deferral is the *common* outcome of this command, not an
        # unusual one. A run truncated partway through a page walk is `completed`, not
        # deferred, so it keeps its counts.
        report(result.deferred? ? nil : result.tally) { |summary| outcome_line(result, summary) }
        Result.new(outcome: result.status.to_sym, exit_code: result.failed? ? FAILURE : SUCCESS)
      rescue Errors::SourceBusy
        # §9's wording, verbatim. No run row exists — the runner opens one inside the lock —
        # so there is no tally to print, only the state that already existed.
        report { BUSY_MESSAGE }
        Result.new(outcome: :busy, exit_code: SUCCESS)
      rescue *REFUSING_ERRORS => error
        @error_output.puts("#{humanize(error)}: #{error.message}")
        report
        Result.new(outcome: :refused, exit_code: REFUSED)
      end

      # §9's summary is printed on every path that has a database, including the failing and
      # deferred ones — captured *after* the lock is released, so it reflects the run's own
      # writes. Composed and written as one string so a concurrent log line cannot split it.
      #
      # The snapshot is taken before the headline is built and handed to the block, so a
      # headline that needs persisted state reads it from the same snapshot the block below
      # prints. This class asks the database nothing directly.
      def report(tally = nil)
        summary = StateSummary.capture
        headline = block_given? ? yield(summary) : nil

        @output.puts([ headline, tally&.to_s, summary.to_s ].compact.join("\n\n"))
      rescue StandardError => error
        # A summary that cannot be read must not mask the outcome that was already decided.
        @error_output.puts("State summary unavailable: #{error.class.name}")
      end

      def outcome_line(result, summary)
        case result.status
        when "completed" then "Ingestion run #{result.run_id} completed"
        when "not_modified" then "Ingestion run #{result.run_id} completed — GitHub reported no changes (304)"
        when "deferred" then deferred_line(result, summary)
        else "Ingestion run #{result.run_id} failed: #{result.last_error}"
        end
      end

      # §9's line is "Ingestion deferred until T", where T comes from effective_poll_time —
      # computed by the runner against the same `force` the run used, so a forced run can
      # never print an unforced instant.
      #
      # An instant is printed only when one is both known and still in the future. A
      # constraint that has already passed while another still holds — a spent cadence
      # under a live global block, say — would otherwise print a time in the past, which
      # reads as a bug rather than as information.
      def deferred_line(result, summary)
        instant = Report.timestamp(deferred_until(result, summary))
        until_clause = instant ? " until #{instant}" : ""

        "Ingestion deferred#{until_clause} — #{result.deferral_reason}"
      end

      def deferred_until(result, summary)
        return nil if NO_INSTANT_REASONS.include?(result.deferral_reason)
        return summary.budget_reset_at if reset_backed?(result)

        result.next_poll_at
      end

      def reset_backed?(result)
        RESET_BACKED_REASONS.include?(result.deferral_reason)
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
