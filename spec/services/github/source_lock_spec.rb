require "rails_helper"

RSpec.describe Github::SourceLock do
  let(:namespace) { Github::AdvisoryLock::SOURCE_LOCK_NAMESPACE }
  let(:source) { create_event_source }

  describe ".acquire" do
    it "owns the source for the duration of the block, and only then" do
      available_inside = nil

      described_class.acquire(source.id) { available_inside = lock_available_to_other_session?(namespace, source.id) }

      expect(available_inside).to be(false)
      expect(lock_available_to_other_session?(namespace, source.id)).to be(true)
    end

    # §2A: the poller attempts once and exits. A blocking wait would pin a worker
    # thread and a pool connection behind a holder that legitimately owns the source
    # for a whole multi-page operation, and deferral costs nothing — the recurring task
    # fires again in 60 seconds.
    it "lets the poller attempt once and report the source busy" do
      polled = false

      other_session_holding(namespace, source.id) do
        suppress(Github::Errors::SourceBusy) { described_class.acquire(source.id) { polled = true } }
      end

      expect(polled).to be(false)
    end

    it "reports busy as a deferral rather than a source failure" do
      other_session_holding(namespace, source.id) do
        expect { described_class.acquire(source.id) { nil } }
          .to raise_error(Github::Errors::SourceBusy, /locked by another session/)
      end
    end

    # §9 pins the one-shot's contract: retry pg_try_advisory_lock for up to
    # SOURCE_LOCK_WAIT_SECONDS. Asserted with a scripted clock and a recording sleeper,
    # so the 30-second contract costs no wall-clock time and cannot flake.
    it "lets the one-shot retry until its deadline and then report busy" do
      slept = []

      other_session_holding(namespace, source.id) do
        expect {
          described_class.acquire(
            source.id,
            wait_seconds: 0.75, retry_interval: 0.25,
            clock: scripted_clock(0.0, 0.0, 0.25, 0.50, 1.00), sleeper: ->(seconds) { slept << seconds }
          ) { nil }
        }.to raise_error(Github::Errors::SourceBusy)
      end

      expect(slept).to eq([ 0.25, 0.25, 0.25 ])
    end

    it "defaults the one-shot's wait to the value the plan pins" do
      expect(Github.configuration.source_lock_wait_seconds).to eq(30)
    end

    # Two sources must poll concurrently: the lock is per source, and a shared key
    # would serialise every source behind whichever polled first.
    it "grants two different sources at the same time" do
      other = create_event_source(source_type: "github_repository_events")

      described_class.acquire(source.id) do
        expect { |probe| described_class.acquire(other.id, &probe) }.to yield_control
      end
    end

    it "releases the lock when the block raises" do
      expect { described_class.acquire(source.id) { raise "boom" } }.to raise_error("boom")

      expect(lock_available_to_other_session?(namespace, source.id)).to be(true)
    end

    it "refuses a nested acquisition of the same source, which PostgreSQL would allow" do
      described_class.acquire(source.id) do
        expect { described_class.acquire(source.id) { nil } }.to raise_error(Github::Errors::ReentrantLock)
      end
    end

    it "refuses a source id outside the advisory key space before taking any lock" do
      expect { described_class.acquire(2**31) { nil } }.to raise_error(ArgumentError)
    end

    it "requires a block, because a lock with no scope has no release" do
      expect { described_class.acquire(source.id) }.to raise_error(ArgumentError, /requires a block/)
    end

    it "returns the block's value" do
      expect(described_class.acquire(source.id) { :polled }).to eq(:polled)
    end
  end

  describe "#held?" do
    it "reports ownership only inside the block" do
      expect(described_class).not_to be_held(source.id)
      described_class.acquire(source.id) { expect(described_class).to be_held(source.id) }
      expect(described_class).not_to be_held(source.id)
    end
  end
end
