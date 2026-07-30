require "rails_helper"

RSpec.describe Github::Ingestion::SourceProvisioner do
  describe ".ensure!" do
    it "creates the row a clean checkout does not have" do
      expect { described_class.ensure!(mode: :live, now: frozen_time) }
        .to change(EventSource, :count).by(1)

      expect(EventSource.sole).to have_attributes(
        source_type: "github_public_events", status: "idle", enabled: true, configuration: {}
      )
    end

    # §6's mode mapping, through the same EventSources::Base.for_mode the adapter selection
    # uses — so the row a process provisions always matches the adapter it will poll with.
    it "provisions the fixture source in fixture mode" do
      expect(described_class.ensure!(mode: :fixture).source_type).to eq("github_fixture_events")
    end

    it "is idempotent" do
      first = described_class.ensure!(mode: :live)

      expect { described_class.ensure!(mode: :live) }.not_to change(EventSource, :count)
      expect(described_class.ensure!(mode: :live).id).to eq(first.id)
    end

    # "failed" rather than any other value on purpose: it is the one status an operator has
    # to clear by hand (§10), so provisioning silently resetting it would put a source
    # someone took out of service straight back into rotation.
    it "never changes a row it did not create" do
      existing = create_event_source(source_type: "github_public_events", status: "failed",
                                     configuration: { "endpoint" => "/events" })

      described_class.ensure!(mode: :live)

      expect(existing.reload).to have_attributes(status: "failed",
                                                 configuration: { "endpoint" => "/events" })
    end

    # Duplicate rows can predate this code or be created by hand, and every process has to
    # derive the same advisory lock key from them or the source lock stops protecting the
    # source.
    it "converges on the lowest id when several rows of the type exist" do
      first = create_event_source(source_type: "github_public_events")
      create_event_source(source_type: "github_public_events")

      expect(described_class.ensure!(mode: :live).id).to eq(first.id)
    end

    # source_type is deliberately not unique (§6 anticipates per-repository sources), so a
    # bare check-then-insert would let two first-time processes each end up on the row *it*
    # created, take source locks on two different event_source.id values, and poll the same
    # feed concurrently — the exact guarantee §9 asks the source lock to provide.
    describe "two processes provisioning at once" do
      it "serializes the check and the insert against a second session" do
        expect(EventSource.connection).to receive(:execute)
          .with(described_class::PROVISIONING_LOCK).and_call_original

        described_class.ensure!(mode: :live)
      end

      # The lock self-conflicts, so a second session cannot hold it while provisioning runs.
      # Asserted with a real out-of-pool connection, because a thread would share this
      # session and the assertion would pass no matter what the code did.
      it "takes a lock a concurrent provisioner would have to wait for" do
        second_session.exec("BEGIN; LOCK TABLE event_sources IN SHARE ROW EXCLUSIVE MODE")

        blocked = second_session.exec(<<~SQL).getvalue(0, 0)
          SELECT count(*) FROM pg_locks
          WHERE relation = 'event_sources'::regclass AND mode = 'ShareRowExclusiveLock'
        SQL

        expect(blocked.to_i).to eq(1)
      ensure
        second_session.exec("ROLLBACK")
      end

      # Every call after the first is a single SELECT: #ensure! reads before it ever reaches
      # the transaction, so the table lock is a first-write cost and not a per-run one.
      it "does not lock the table once the row exists" do
        described_class.ensure!(mode: :live)

        expect(EventSource.connection).not_to receive(:execute).with(described_class::PROVISIONING_LOCK)

        described_class.ensure!(mode: :live)
      end
    end

    it "keeps sources of different types apart" do
      live = described_class.ensure!(mode: :live)
      fixture = described_class.ensure!(mode: :fixture)

      expect(live.id).not_to eq(fixture.id)
      expect(EventSource.count).to eq(2)
    end

    it "defaults to the configured mode" do
      expect(described_class.ensure!.source_type)
        .to eq(Github::EventSources::Base.for_mode(Github.configuration.mode).source_type)
    end
  end
end
