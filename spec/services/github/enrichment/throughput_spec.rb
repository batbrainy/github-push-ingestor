require "rails_helper"

RSpec.describe Github::Enrichment::Throughput do
  let(:now) { frozen_time }

  def from(configuration: Github.configuration)
    backlog = Github::Enrichment::BacklogMetrics.capture(now: now,
                                                         configuration: configuration)
    described_class.from(backlog, now: now, configuration: configuration)
  end

  describe "the sample window" do
    # No entities means no observed history at all: there is nothing to divide by, so
    # the rates are null and the verdict refuses to claim anything either way.
    it "reports no sample and no rates on a fresh database" do
      throughput = from

      expect(throughput).to have_attributes(sample_started_at: nil, sample_seconds: nil,
                                            catch_up_state: "insufficient_sample")
      expect(throughput.combined).to have_attributes(
        arrivals: 0, completions: 0, terminals: 0, exits: 0,
        arrival_rate_per_hour: nil, completion_rate_per_hour: nil, backlog_delta: 0
      )
      expect(throughput.to_s).to eq("Keeping up: insufficient sample (0s < 900s)")
    end

    # A table younger than the window must not divide by the full hour — that would
    # understate every rate. The sample starts at the oldest row the table has held.
    it "truncates the sample to the earliest created_at inside the window" do
      create_actor(github_id: 1, created_at: now - 1200)

      throughput = from

      expect(throughput).to have_attributes(sample_started_at: now - 1200,
                                            sample_seconds: 1200)
      expect(throughput.actor.arrival_rate_per_hour).to eq(3.0)
    end

    it "spans at most the metrics window however old the table is" do
      create_actor(github_id: 1, enrichment_status: "complete",
                   enrichment_stage: "contract_complete", created_at: now - 90_000,
                   contract_completed_at: now - 90_000)

      expect(from).to have_attributes(sample_started_at: now - 3600,
                                      sample_seconds: 3600)
    end
  end

  describe "the catch-up verdict" do
    it "is insufficient_sample until the history spans the configured minimum" do
      create_actor(github_id: 1, created_at: now - 100)

      expect(from).to have_attributes(sample_seconds: 100,
                                      catch_up_state: "insufficient_sample")
    end

    it "is keeping_up when the backlog shrank over the window" do
      create_actor(github_id: 1, enrichment_status: "complete",
                   enrichment_stage: "contract_complete", created_at: now - 5000,
                   contract_completed_at: now - 60)

      throughput = from

      expect(throughput.combined).to have_attributes(arrivals: 0, exits: 1,
                                                     backlog_delta: -1)
      expect(throughput.catch_up_state).to eq("keeping_up")
      expect(throughput.to_s).to start_with("Keeping up: yes")
    end

    it "is keeping_up on a level window only with zero contract debt" do
      create_actor(github_id: 1, enrichment_status: "complete",
                   enrichment_stage: "contract_complete", created_at: now - 5000,
                   contract_completed_at: now - 5000)

      throughput = from

      expect(throughput.combined.backlog_delta).to eq(0)
      expect(throughput.catch_up_state).to eq("keeping_up")
    end

    # The honest verdict issue #45 asks for: a backlog that holds level while contract
    # debt exists is not being caught up on, even though nothing got worse.
    it "is not_keeping_up on a flat nonzero backlog" do
      create_actor(github_id: 1, created_at: now - 1000)
      create_repository(github_id: 2, enrichment_status: "complete",
                        enrichment_stage: "contract_complete", created_at: now - 5000,
                        contract_completed_at: now - 30)

      throughput = from

      expect(throughput.combined).to have_attributes(arrivals: 1, exits: 1,
                                                     backlog_delta: 0)
      expect(throughput.catch_up_state).to eq("not_keeping_up")
      expect(throughput.to_s).to start_with("Keeping up: NO")
    end

    it "reads the minimum sample from the configuration it was given" do
      create_actor(github_id: 1, created_at: now - 100)
      configuration = configuration_with(CATCH_UP_MIN_SAMPLE_SECONDS: "60")

      throughput = from(configuration: configuration)

      expect(throughput).to have_attributes(min_sample_seconds: 60,
                                            catch_up_state: "not_keeping_up")
    end
  end

  describe "the lane arithmetic" do
    # backlog_delta is arrivals minus exits — a counted slope, not a fit or a forecast —
    # and a terminal outcome is an exit exactly as a completion is.
    it "computes exits and the backlog delta from arrivals, completions and terminals" do
      create_actor(github_id: 1, created_at: now - 1000)
      create_actor(github_id: 2, created_at: now - 900)
      create_actor(github_id: 3, enrichment_status: "complete",
                   enrichment_stage: "contract_complete", created_at: now - 7200,
                   contract_completed_at: now - 20)
      create_actor(github_id: 4, enrichment_status: "permanent_failure",
                   enrichment_stage: "terminal", created_at: now - 7200,
                   terminal_at: now - 10)

      expect(from.actor).to have_attributes(
        arrivals: 2, completions: 1, terminals: 1, exits: 2, backlog_delta: 0
      )
    end

    it "combines both lanes and rates the combined counts over the shared sample" do
      create_actor(github_id: 1, created_at: now - 1800)
      create_repository(github_id: 2, created_at: now - 900)

      throughput = from

      expect(throughput.combined).to have_attributes(arrivals: 2, backlog_delta: 2)
      # Two arrivals over the 1800-second sample the older row anchors: 2 * 3600 / 1800.
      expect(throughput.combined.arrival_rate_per_hour).to eq(4.0)
      expect(throughput.actor.arrival_rate_per_hour).to eq(2.0)
    end
  end

  describe "#payload" do
    it "publishes a fixed key set with the verdict beside its threshold" do
      create_actor(github_id: 1, created_at: now - 600)

      payload = from.payload

      expect(payload.keys).to eq(%i[window_seconds window_start sample_started_at
                                    sample_seconds actors repositories combined catch_up])
      expect(payload).to include(window_seconds: 3600,
                                 window_start: (now - 3600).utc.iso8601,
                                 sample_started_at: (now - 600).utc.iso8601,
                                 sample_seconds: 600)
      expect(payload[:actors].keys).to eq(%i[arrivals completions terminals exits
                                             arrival_rate_per_hour
                                             completion_rate_per_hour backlog_delta])
      expect(payload[:catch_up]).to eq(state: "insufficient_sample",
                                       min_sample_seconds: 900)
    end
  end
end
