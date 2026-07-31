require "rails_helper"

RSpec.describe EventSource do
  describe "scheduling components" do
    # Plan §9: the constraints are persisted separately, never collapsed into one
    # timestamp — otherwise --force could not tell which part it may bypass, and a
    # routine X-RateLimit-Reset would wrongly defer every poll to the top of the hour.
    it "holds each component independently" do
      source = create_event_source(
        cadence_due_at: frozen_time + 300,
        poll_floor_until: frozen_time + 60,
        retry_not_before_at: frozen_time + 900,
        next_poll_at: frozen_time + 900
      )

      source.reload
      expect(source.cadence_due_at).to eq(frozen_time + 300)
      expect(source.poll_floor_until).to eq(frozen_time + 60)
      expect(source.retry_not_before_at).to eq(frozen_time + 900)
      expect(source.next_poll_at).to eq(frozen_time + 900)
    end

    it "leaves every component unset on a new source" do
      source = create_event_source

      expect(source.cadence_due_at).to be_nil
      expect(source.poll_floor_until).to be_nil
      expect(source.retry_not_before_at).to be_nil
      expect(source.next_poll_at).to be_nil
    end

    it "can clear one component without disturbing the others" do
      source = create_event_source(cadence_due_at: frozen_time + 300,
                                   poll_floor_until: frozen_time + 60)

      source.update!(cadence_due_at: nil)

      expect(source.reload.poll_floor_until).to eq(frozen_time + 60)
    end
  end

  describe "rate-limit state" do
    # V1 stored rate-limit state per source; V2 moved it to the global ledger because
    # enrichment requests are not tied to a source row and the budget is per-IP (§7).
    it "keeps no per-source rate-limit columns" do
      expect(described_class.column_names.grep(/rate_limit|remaining|allowance/)).to be_empty
    end
  end

  describe "defaults" do
    it "is enabled with no failures and an empty configuration" do
      source = described_class.create!(source_type: "github_public_events", status: "idle")

      expect(source).to be_enabled
      expect(source.consecutive_failures).to eq(0)
      expect(source.configuration).to eq({})
    end
  end

  describe "the page-one ETag" do
    it "is stored per source and starts unset" do
      expect(create_event_source.etag).to be_nil
      expect(create_event_source(etag: 'W/"abc123"').etag).to eq('W/"abc123"')
    end
  end

  # Two values, and the elimination is the point. Whether a poll is in flight is the source
  # advisory lock's answer — authoritative and crash-safe, which a status column is not.
  # When the next poll is due is effective_poll_time's, derived from four independent
  # columns; storing a "deferred" beside them would be the collapsed timestamp §9 forbids.
  # How badly a source is failing is consecutive_failures'. What is left is the one thing
  # nothing else expresses: why a source is out of service.
  describe "the poll state machine" do
    it "accepts the status the provisioner has always written" do
      expect(create_event_source(status: "idle")).to be_idle
    end

    # §10: "/events returns permanent 4xx → source failed/disabled". Terminal on first
    # occurrence, and cleared by an operator rather than automatically — nothing in the
    # plan defines a transition back, and inventing one would silently re-enable a source
    # a human took out.
    it "records a source taken out of service by a permanent client error" do
      expect(create_event_source(status: "failed")).to be_failed
    end

    # `validate: true` on the enum, so an unknown value is a validation failure rather than
    # the ArgumentError a bare Rails enum raises — matching IngestionRun and
    # GithubApiBudget, and keeping an invalid assignment recoverable instead of fatal.
    it "refuses a status outside the vocabulary" do
      expect { create_event_source(status: "polling") }
        .to raise_error(ActiveRecord::RecordInvalid, /Status is not included/)
    end

    # The validation is the guard for application writes; the constraint is the guard for
    # everything else, matching the two vocabularies already in this schema
    # (github_api_budget.window_status and the enrichment_status of both entity tables).
    it "refuses one at the database too, where a validation cannot reach" do
      expect_violation(ActiveRecord::StatementInvalid) do
        described_class.insert!(event_source_attributes.merge(status: "polling"))
      end
    end

    # enabled means an operator turned this off; status means the system took it out of
    # service. Two representations of "off" would be the drift trap, so they stay distinct.
    it "keeps `enabled` as a separate question from `status`" do
      source = create_event_source(status: "failed")

      expect(source).to be_enabled
    end
  end

  describe "database constraints" do
    it "requires a source type and a status" do
      %i[source_type status].each do |column|
        expect_violation(ActiveRecord::NotNullViolation) do
          described_class.insert!(event_source_attributes.except(column))
        end
      end
    end

    it "rejects a negative failure count" do
      source = create_event_source

      expect_violation(ActiveRecord::CheckViolation) do
        described_class.where(id: source.id).update_all(consecutive_failures: -1)
      end
    end

    # Several live sources may share a type — plan §6 anticipates per-repository event
    # sources — so the type is deliberately not unique.
    it "allows more than one source of the same type" do
      create_event_source
      expect { create_event_source }.to change(described_class, :count).by(1)
    end
  end

  # PR 8's recurring tick asks this once a minute. It is a pre-filter over the cached
  # projection, never the decision — Github::IngestionRunner reloads the row inside the
  # source lock and Github::PollSchedule decides there, from §9's four components.
  # PR 9 pulled this out of .poll_due so §10's allowance formula and the poll filter are one
  # predicate: Github::SourceAllocation counts these rows to derive ENABLED_LIVE_SOURCE_COUNT,
  # and a source the tick would never pick up must not have poll allowance reserved for it.
  describe ".pollable" do
    def pollable(source_type: "github_public_events")
      described_class.pollable(source_type: source_type)
    end

    it "ignores the schedule, which is about when rather than whether" do
      soon = create_event_source(next_poll_at: frozen_time + 86_400)

      expect(pollable).to contain_exactly(soon)
    end

    it "excludes a source belonging to another mode" do
      create_event_source(source_type: "github_fixture_events")

      expect(pollable).to be_empty
    end

    it "excludes a disabled source" do
      create_event_source(enabled: false)

      expect(pollable).to be_empty
    end

    it "excludes a source that is out of service" do
      create_event_source(status: "failed")

      expect(pollable).to be_empty
    end
  end

  describe ".poll_due" do
    def due(now: frozen_time, source_type: "github_public_events")
      described_class.poll_due(source_type: source_type, now: now)
    end

    # A freshly provisioned source has never been polled, so its projection is NULL. If that
    # did not count as due, a clean checkout would never poll at all.
    it "includes a source that has never been polled" do
      source = create_event_source(next_poll_at: nil)

      expect(due).to contain_exactly(source)
    end

    it "includes a source whose projection has arrived, and excludes one whose has not" do
      overdue = create_event_source(next_poll_at: frozen_time - 1)
      create_event_source(next_poll_at: frozen_time + 1)

      expect(due).to contain_exactly(overdue)
    end

    # <= rather than <, matching PollSchedule#due? and for its reason: PostgreSQL truncates a
    # timestamp to microseconds on the way in and Time.current does not.
    it "includes a source due at exactly this instant" do
      source = create_event_source(next_poll_at: frozen_time)

      expect(due).to contain_exactly(source)
    end

    # A live worker polling a fixture source raises Errors::FixtureMiss once a minute
    # forever, and the reverse is refused by Github::UrlPolicy — and a development database
    # routinely holds both rows, because the README's reviewer path creates one.
    it "excludes a source belonging to another mode" do
      create_event_source(source_type: "github_fixture_events", next_poll_at: nil)

      expect(due).to be_empty
    end

    # An operator turned it off; the tick has nothing to say about that.
    it "excludes a disabled source" do
      create_event_source(enabled: false, next_poll_at: nil)

      expect(due).to be_empty
    end

    # §10's "/events returns permanent 4xx → source failed": operator-recoverable only. The
    # runner would refuse it anyway, with a warning — once a minute, until someone looked.
    it "excludes a source that is out of service" do
      create_event_source(status: "failed", next_poll_at: nil)

      expect(due).to be_empty
    end

    # Ordered, so a tick with several due sources spends the budget in the same order every
    # time rather than in whatever order PostgreSQL finds convenient.
    it "returns due sources in a stable order" do
      first = create_event_source(next_poll_at: nil)
      second = create_event_source(next_poll_at: frozen_time - 60)

      expect(due.map(&:id)).to eq([ first.id, second.id ].sort)
    end
  end

  describe "associations" do
    it "will not be destroyed while runs reference it" do
      source = create_event_source
      IngestionRun.create!(event_source: source, started_at: frozen_time, status: "running")

      expect(source.destroy).to be(false)
      expect(described_class.count).to eq(1)
    end
  end
end
