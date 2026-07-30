require "rails_helper"

RSpec.describe Github::RequestGate do
  let(:namespace) { Github::AdvisoryLock::REQUEST_GATE_NAMESPACE }
  let(:key) { Github::AdvisoryLock::REQUEST_GATE_KEY }

  describe ".hold" do
    # §2A: at most one live GitHub request in flight across the poller, the worker, and
    # the one-shot. Without this, two processes reserve against the same window
    # concurrently and the ledger's accounting stops meaning anything.
    it "excludes every other session for the duration of the block, and only then" do
      available_inside = nil

      described_class.hold { available_inside = lock_available_to_other_session?(namespace, key) }

      expect(available_inside).to be(false)
      expect(lock_available_to_other_session?(namespace, key)).to be(true)
    end

    # A blocking acquire with no bound has no failing outcome to assert: a broken gate
    # spec would hang CI rather than fail it. lock_timeout turns waiting into a typed,
    # catchable outcome. The example is deterministic — the lock is definitely held by
    # the second session, so the timeout can only fire.
    it "defers instead of waiting forever when another process holds the gate" do
      other_session_holding(namespace, key) do
        expect { described_class.hold(wait_seconds: 0.1) { raise "must not run" } }
          .to raise_error(Github::Errors::GateUnavailable)
      end
    end

    it "leaves the gate free after a deferral, having acquired nothing" do
      other_session_holding(namespace, key) do
        suppress(Github::Errors::GateUnavailable) { described_class.hold(wait_seconds: 0.1) { nil } }
      end

      expect(lock_available_to_other_session?(namespace, key)).to be(true)
    end

    it "releases the gate when the block raises, so one failure cannot stall the system" do
      expect { described_class.hold { raise "boom" } }.to raise_error("boom")

      expect(lock_available_to_other_session?(namespace, key)).to be(true)
    end

    # PostgreSQL session advisory locks are re-entrant, so a nested acquisition
    # succeeds and one execution context would have two requests in flight — the exact
    # thing the gate exists to prevent.
    it "refuses a nested hold rather than silently permitting two in-flight requests" do
      described_class.hold do
        expect { described_class.hold { nil } }.to raise_error(Github::Errors::ReentrantLock)
      end
    end

    it "reports whether the gate is currently held on this execution context" do
      expect(described_class).not_to be_held
      described_class.hold { expect(described_class).to be_held }
      expect(described_class).not_to be_held
    end

    it "returns the block's value, so it can wrap an expression" do
      expect(described_class.hold { 200 }).to eq(200)
    end

    it "requires a block, because a lock with no scope has no release" do
      expect { described_class.hold }.to raise_error(ArgumentError, /requires a block/)
    end
  end

  describe "the wait bound" do
    # A legitimate hold is one HTTP attempt: 5s connect plus 15s read, plus two
    # sub-millisecond ledger transactions. Retries re-acquire rather than extending a
    # hold, so nothing can legitimately hold longer than that.
    it "exceeds the longest possible legitimate hold" do
      configuration = Github.configuration
      longest_hold = configuration.http_open_timeout_seconds + configuration.http_read_timeout_seconds

      expect(described_class::WAIT_SECONDS).to be > longest_hold
    end
  end

  describe "the lock-order invariant" do
    # §2A, §5, CLAUDE.md: source lock -> request gate, never the reverse. Getting this
    # wrong deadlocks two containers with nothing in the logs, so it raises instead of
    # relying on the structural separation alone.
    it "refuses a source lock taken while the gate is held" do
      described_class.hold do
        expect { Github::SourceLock.acquire(1) { nil } }
          .to raise_error(Github::Errors::LockOrderViolation, /never the reverse/)
      end
    end

    it "permits the documented order" do
      expect(Github::SourceLock.acquire(1) { described_class.hold { :fetched } }).to eq(:fetched)
    end
  end
end
