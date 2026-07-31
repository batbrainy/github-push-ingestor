require "rails_helper"

# §12's "Advisory locks released on session death (simulated connection kill)" — the
# verification half of Extension B's crash-safe source ownership, and the property the whole
# lock design rests on: §2A chose session advisory locks over a FOR UPDATE row claim precisely
# because "hard process/container death closes the session and releases the lock
# automatically".
#
# The kill is pg_terminate_backend, not a client-side close. A close is the client
# cooperating — it proves locks are session-scoped and no application ensure block was
# involved, which the suite's own teardown demonstrates incidentally. A terminate ends the
# backend with no client cooperation and no Ruby running anywhere in the "dead process", which
# is what a `docker kill` does to a worker mid-poll.
#
# The residual gap, stated rather than papered over: the dying session cannot be the RSpec
# process's own pooled connection, because killing that backend would take the example's
# fixture transaction with it. §15's container kill closes that last gap, and it is a reviewer
# step (PR 11), not a unit test.
RSpec.describe "advisory locks after session death", type: :integration do
  let(:source_namespace) { Github::AdvisoryLock::SOURCE_LOCK_NAMESPACE }
  let(:gate_namespace) { Github::AdvisoryLock::REQUEST_GATE_NAMESPACE }
  let(:event_source) { create_event_source }
  let(:source_key) { Github::AdvisoryLock.key_for(event_source.id) }

  describe "a source lock held by a session that dies" do
    before { acquire_in_other_session(source_namespace, source_key) }

    it "blocks the application while that session is alive" do
      expect { Github::SourceLock.acquire(event_source.id) { :polled } }
        .to raise_error(Github::Errors::SourceBusy)
    end

    it "is released by PostgreSQL, with nothing in this application running to release it" do
      pid = terminate_second_session!
      wait_for_advisory_lock_release(source_namespace, source_key)

      expect(advisory_lock_holders(source_namespace, source_key)).to be_empty
      expect(pid).to be_positive
    end

    # Through the production wait rather than a hand-rolled sleep: pg_terminate_backend
    # returns before the backend has finished exiting, so what is asserted is the contract a
    # real poller relies on — SourceLock retries for its wait_seconds and gets the lock.
    it "lets the next poller take the lock" do
      terminate_second_session!

      expect(Github::SourceLock.acquire(event_source.id, wait_seconds: 5) { :polled }).to eq(:polled)
    end

    it "leaves the lock free again once that poller is done" do
      terminate_second_session!
      Github::SourceLock.acquire(event_source.id, wait_seconds: 5) { :polled }

      expect(advisory_lock_holders(source_namespace, source_key)).to be_empty
    end
  end

  # The gate is the lock whose leak would stop every request in the system, polling and
  # enrichment alike — so it gets the same proof rather than an argument by analogy.
  describe "the request gate held by a session that dies" do
    before { acquire_in_other_session(gate_namespace, Github::AdvisoryLock::REQUEST_GATE_KEY) }

    it "blocks the application while that session is alive" do
      expect { Github::RequestGate.hold(wait_seconds: 0.1) { :requested } }
        .to raise_error(Github::Errors::GateUnavailable)
    end

    it "lets the next request through once the holder's session is gone" do
      terminate_second_session!
      wait_for_advisory_lock_release(gate_namespace, Github::AdvisoryLock::REQUEST_GATE_KEY)

      expect(Github::RequestGate.hold(wait_seconds: 5) { :requested }).to eq(:requested)
    end
  end

  # The headline: a whole polling operation, through production code on both sides of the
  # kill. Before, the poller finds the source owned and leaves no trace; after, the same
  # runner polls it and persists the page.
  describe "a poll blocked by a dead worker's lock", type: :integration do
    let(:transport) { fixture_transport }
    let(:event_source) { fixture_event_source }

    before { active_budget_window(now: frozen_time) }

    it "recovers the source without an operator or a cleanup job" do
      acquire_in_other_session(source_namespace, source_key)

      expect { fixture_runner(transport: transport).call(event_source: event_source) }
        .to raise_error(Github::Errors::SourceBusy)
      expect(IngestionRun.count).to eq(0)
      expect(transport.requests).to be_empty

      terminate_second_session!

      result = fixture_runner(transport: transport)
               .call(event_source: event_source, wait_seconds: 5)

      expect(result).to be_completed
      expect(PushEvent.count).to eq(4)
    end
  end
end
