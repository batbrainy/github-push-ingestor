module Github
  module Enrichment
    # Issue #45's catch-up accounting: measured arrivals versus measured completions
    # over the trailing metrics window, and the honest tri-state verdict. Built entirely
    # from the BacklogMetrics aggregate — no queries of its own — so this block can
    # never contradict the per-stage counts published beside it.
    #
    # There is deliberately no drained-by estimate anywhere: the measured numbers are
    # the whole claim, and when the service is not keeping up the verdict says so.
    class Throughput < Data.define(:window_seconds, :window_start, :sample_started_at,
                                   :sample_seconds, :actor, :repository, :combined,
                                   :catch_up_state, :min_sample_seconds)
      Lane = Data.define(:arrivals, :completions, :terminals, :exits,
                         :arrival_rate_per_hour, :completion_rate_per_hour,
                         :backlog_delta)

      STATES = %w[ keeping_up not_keeping_up insufficient_sample ].freeze

      class << self
        # @param backlog [BacklogMetrics] the shared aggregate Snapshot captured once.
        def from(backlog, now: Time.current, configuration: Github.configuration)
          window_seconds = backlog.window_seconds
          window_start = now - window_seconds
          earliest = [ backlog.actor.earliest_created_at,
                       backlog.repository.earliest_created_at ].compact.min
          sample_started_at = earliest.nil? ? nil : [ window_start, earliest ].max
          sample_seconds = sample_started_at && [ (now - sample_started_at).floor, 0 ].max

          actor = lane(backlog.actor, sample_seconds)
          repository = lane(backlog.repository, sample_seconds)
          combined = combine(actor, repository, sample_seconds)
          contract_backlog = backlog.actor.contract_backlog_count +
                             backlog.repository.contract_backlog_count

          new(window_seconds: window_seconds, window_start: window_start,
              sample_started_at: sample_started_at, sample_seconds: sample_seconds,
              actor: actor, repository: repository, combined: combined,
              catch_up_state: state(combined, contract_backlog, sample_seconds, configuration),
              min_sample_seconds: configuration.catch_up_min_sample_seconds)
        end

        private

        def lane(entry, sample_seconds)
          exits = entry.completions + entry.terminals
          Lane.new(
            arrivals: entry.arrivals, completions: entry.completions,
            terminals: entry.terminals, exits: exits,
            arrival_rate_per_hour: rate(entry.arrivals, sample_seconds),
            completion_rate_per_hour: rate(entry.completions, sample_seconds),
            # Arrivals minus exits over the window: the backlog slope as a counted
            # number, negative while draining. Not a fit, not a forecast.
            backlog_delta: entry.arrivals - exits
          )
        end

        def combine(actor, repository, sample_seconds)
          arrivals = actor.arrivals + repository.arrivals
          completions = actor.completions + repository.completions
          terminals = actor.terminals + repository.terminals
          Lane.new(
            arrivals: arrivals, completions: completions, terminals: terminals,
            exits: completions + terminals,
            arrival_rate_per_hour: rate(arrivals, sample_seconds),
            completion_rate_per_hour: rate(completions, sample_seconds),
            backlog_delta: arrivals - (completions + terminals)
          )
        end

        def rate(count, sample_seconds)
          return nil if sample_seconds.nil? || sample_seconds.zero?

          (count * 3600.0 / sample_seconds).round(2)
        end

        # insufficient_sample until the observed history spans the configured minimum;
        # keeping_up when the backlog shrank over the window, or held level with zero
        # contract debt; not_keeping_up otherwise — including a flat nonzero backlog.
        def state(combined, contract_backlog, sample_seconds, configuration)
          if sample_seconds.nil? || sample_seconds < configuration.catch_up_min_sample_seconds
            return "insufficient_sample"
          end
          return "keeping_up" if combined.backlog_delta.negative?
          return "keeping_up" if combined.backlog_delta.zero? && contract_backlog.zero?

          "not_keeping_up"
        end
      end

      def payload
        {
          window_seconds: window_seconds,
          window_start: Ingestion::Report.timestamp(window_start),
          sample_started_at: Ingestion::Report.timestamp(sample_started_at),
          sample_seconds: sample_seconds,
          actors: actor.to_h,
          repositories: repository.to_h,
          combined: combined.to_h,
          catch_up: { state: catch_up_state, min_sample_seconds: min_sample_seconds }
        }
      end

      def to_s
        case catch_up_state
        when "keeping_up"
          "Keeping up: yes (completions #{combined.completion_rate_per_hour}/hr vs " \
            "arrivals #{combined.arrival_rate_per_hour}/hr, backlog delta #{combined.backlog_delta})"
        when "not_keeping_up"
          "Keeping up: NO (completions #{combined.completion_rate_per_hour}/hr vs " \
            "arrivals #{combined.arrival_rate_per_hour}/hr, backlog delta #{combined.backlog_delta})"
        else
          "Keeping up: insufficient sample (#{sample_seconds || 0}s < #{min_sample_seconds}s)"
        end
      end
    end
  end
end
