require "rails_helper"

# Appendix G's first stage, which is not a stage at all but three instants: the accepted
# event's identity fragments become append-only observations, the locally derivable
# fields are derived, and the entity enters the batch FIFO — all inside the ingest
# transaction, with zero enrichment HTTP anywhere.
#
# Page 1 of the default corpus persists four push events (1, 2, 3 and 8) across three
# actors and three repositories, which is every count below.
RSpec.describe "event-native derivation at ingest", type: :integration do
  let(:now) { frozen_time }
  let(:transport) { fixture_transport }

  def ingest!
    fixture_runner(transport: transport, now: now).call(event_source: fixture_event_source)
  end

  describe "the observation ledger" do
    before { ingest! }

    it "appends one actor and one repository observation per accepted event" do
      observations = EnrichmentObservation.where(source: "event")

      expect(observations.count).to eq(8)
      expect(observations.group(:entity_kind).count)
        .to eq("actor" => 4, "repository" => 4)
      expect(observations.pluck(:validation_outcome).uniq).to eq([ "event_native" ])
    end

    # The pair commits with its push_events row or not at all: every event observation
    # names the accepted event it arrived on, and the quarantined envelopes of the same
    # page produced none.
    it "ties every observation to the accepted event that carried it" do
      observations = EnrichmentObservation.where(source: "event")

      expect(observations.where(push_event_id: nil)).to be_empty
      expect(observations.distinct.pluck(:push_event_id)).to match_array(PushEvent.pluck(:id))
      expect(observations.group(:push_event_id).count.values).to all(eq(2))
    end

    it "preserves the envelope fragment verbatim, fingerprinted" do
      event = PushEvent.find_by!(github_event_id: "58000000001")
      observation = EnrichmentObservation.find_by!(push_event_id: event.id, entity_kind: "actor")

      expect(observation.raw_payload).to eq(well_formed_envelope.fetch("actor"))
      expect(observation.entity_github_id).to eq(IngestionHelpers::ACTOR_GITHUB_ID)
      expect(observation.payload_fingerprint).to match(/\A\h{64}\z/)
      expect(observation.observed_at).to eq(now)
    end
  end

  describe "the entity rows" do
    before { ingest! }

    it "stamps every derivation instant and rests the row in the batch FIFO" do
      (GithubActor.all + GithubRepository.all).each do |entity|
        expect(entity).to have_attributes(
          enrichment_status: "pending", enrichment_stage: "batch_pending",
          event_native_at: now, derived_at: now, batch_pending_at: now
        )
      end
    end

    # The one derivable field no request is needed for: the envelope's qualified
    # owner/repository form already carries the owner segment.
    it "derives repository owner_login locally" do
      expect(GithubRepository.order(:id).pluck(:full_name, :owner_login)).to eq([
        [ "octocat/Hello-World", "octocat" ],
        [ "monalisa/Spoon-Knife", "monalisa" ],
        [ "deleted-org/gone", "deleted-org" ]
      ])
    end
  end

  describe "the network boundary of derivation" do
    it "issues the poll and nothing else — zero enrichment requests" do
      ingest!

      expect(transport.requests.size).to eq(1)
      expect(transport.requests.map { _1.fetch(:key) }).to all(start_with("/events"))
      expect(WebMock).not_to have_requested(:any, //)
    end
  end

  # §8: repeated observation is expected, and a duplicate event may refresh identity but
  # must never register activity — extended here to the observation ledger and the
  # derivation instants, which are keep-first by construction (COALESCE, not overwrite).
  describe "a duplicate replay of the same page" do
    let(:page) { corpus_page("page-1.json") }

    before do
      Github::Ingestion::PageWriter.new(clock: -> { now })
                                   .write(page, run_id: SecureRandom.uuid)
    end

    def replay!
      Github::Ingestion::PageWriter.new(clock: -> { now + 60 })
                                   .write(page, run_id: SecureRandom.uuid)
    end

    it "appends no new observation" do
      expect { replay! }.not_to change(EnrichmentObservation, :count).from(8)
    end

    it "registers no new activity and restarts no pipeline clock" do
      octocat = GithubActor.find_by!(github_id: IngestionHelpers::ACTOR_GITHUB_ID)
      before_activity = [ octocat.first_seen_at, octocat.last_seen_at, octocat.latest_event_at ]

      replay!

      expect(octocat.reload).to have_attributes(
        first_seen_at: before_activity[0], last_seen_at: before_activity[1],
        latest_event_at: before_activity[2],
        event_native_at: now, derived_at: now, batch_pending_at: now
      )
    end

    it "reports the whole page as duplicates" do
      tally = replay!

      expect(tally.events_created).to eq(0)
      expect(tally.duplicates_skipped).to eq(4)
    end
  end
end
