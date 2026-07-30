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

    it "never changes a row it did not create" do
      existing = create_event_source(source_type: "github_public_events", status: "polling",
                                     configuration: { "endpoint" => "/events" })

      described_class.ensure!(mode: :live)

      expect(existing.reload).to have_attributes(status: "polling",
                                                 configuration: { "endpoint" => "/events" })
    end

    # source_type is deliberately not unique (§6 anticipates per-repository sources), so two
    # concurrent processes on a fresh database can both insert. Converging on the lowest id
    # is what keeps that harmless: both derive the same advisory lock key afterwards, so the
    # source lock still protects the source.
    it "converges on the lowest id when several rows of the type exist" do
      first = create_event_source(source_type: "github_public_events")
      create_event_source(source_type: "github_public_events")

      expect(described_class.ensure!(mode: :live).id).to eq(first.id)
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
