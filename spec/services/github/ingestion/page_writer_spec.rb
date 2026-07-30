require "rails_helper"

RSpec.describe Github::Ingestion::PageWriter do
  subject(:writer) { described_class.new(clock: -> { received_at }) }

  let(:received_at) { frozen_time }
  let(:run_id) { "2f5b9c3e-7a41-4d0c-9b62-1c8e5f0a4d33" }

  # Not Kernel#Array: it would splat a single envelope Hash into its key/value pairs.
  def write(envelopes, at: nil)
    page = envelopes.is_a?(Array) ? envelopes : [ envelopes ]

    described_class.new(clock: -> { at || received_at }).write(page, run_id: run_id)
  end

  describe "one well-formed push event" do
    let!(:tally) { write(well_formed_envelope) }

    it "persists the structured row with §7's typed columns" do
      event = PushEvent.sole

      expect(event.github_event_id).to eq("58000000001")
      expect(event.github_push_id).to eq(27_500_000_001)
      expect(event.github_repository_id).to eq(1_296_269)
      expect(event.github_actor_id).to eq(583_231)
      expect(event.ref).to eq("refs/heads/main")
      expect(event.head_sha).to eq("a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0")
      expect(event.before_sha).to eq("0f9e8d7c6b5a4938271605f4e3d2c1b0a9988776")
      expect(event.occurred_at).to eq(Time.utc(2026, 7, 29, 11, 58, 12))
    end

    # §7: raw retention is semantic, not byte-exact — jsonb does not preserve whitespace or
    # key order, so the assertion is about content equivalence (ADR 0001).
    it "retains the whole envelope as jsonb, not just the extracted fields" do
      expect(PushEvent.sole.raw_payload).to eq(well_formed_envelope)
    end

    it "upserts both stub entities inside the same transaction as the event" do
      expect(GithubActor.sole).to have_attributes(
        github_id: 583_231, login: "octocat", display_login: "octocat",
        api_url: "https://api.github.com/users/octocat", enrichment_status: "pending"
      )
      expect(GithubRepository.sole).to have_attributes(
        github_id: 1_296_269, full_name: "octocat/Hello-World", name: "Hello-World",
        enrichment_status: "pending"
      )
    end

    it "leaves the enrichment-owned fields alone, so a stub never claims to be enriched" do
      expect(GithubActor.sole.name).to be_nil
      expect(GithubActor.sole.raw_payload).to be_nil
      expect(GithubRepository.sole.description).to be_nil
      expect(GithubRepository.sole.fetched_at).to be_nil
    end

    # §7 merge rule 3: only when RETURNING produced a row.
    it "records entity activity for a genuinely new event" do
      expect(GithubActor.sole).to have_attributes(
        first_seen_at: received_at, last_seen_at: received_at,
        latest_event_at: Time.utc(2026, 7, 29, 11, 58, 12)
      )
    end

    it "counts it as created and as a push event seen" do
      expect(tally.to_h).to include(events_created: 1, push_events_seen: 1, duplicates_skipped: 0)
    end
  end

  # GitHub's clock and ours are different clocks, and the documented 30s–6h latency means
  # occurred_at can sit either side of the observation. Nothing may clamp it.
  it "lets latest_event_at exceed last_seen_at when GitHub's timestamp is later" do
    write(well_formed_envelope("created_at" => "2026-07-29T12:00:41Z"), at: frozen_time)

    expect(GithubActor.sole.latest_event_at).to eq(Time.utc(2026, 7, 29, 12, 0, 41))
    expect(GithubActor.sole.last_seen_at).to eq(frozen_time)
  end

  it "keeps the greatest event timestamp when a page arrives out of chronological order" do
    write([
      well_formed_envelope("id" => "1", "created_at" => "2026-07-29T11:59:00Z"),
      well_formed_envelope("id" => "2", "created_at" => "2026-07-29T11:57:00Z")
    ])

    expect(GithubActor.sole.latest_event_at).to eq(Time.utc(2026, 7, 29, 11, 59, 0))
  end

  # §12: "Duplicate poll results (fixture replay) — duplicates skipped and no entity
  # reactivation occurs." Appendix D item 5 is the reason the gate exists at all.
  describe "a duplicate replay" do
    let(:later) { frozen_time + 60 }

    before do
      write(well_formed_envelope)

      # update_all, not update!, and updated_at is held at the frozen instant on purpose:
      # IDENTITY_MERGE gates each assignment on EXCLUDED.updated_at >= the stored value, so
      # a wall-clock touch here would block the refresh and the example would pass for the
      # wrong reason.
      GithubActor.where(github_id: 583_231)
                 .update_all(login: "stale-login", enrichment_status: "skipped_budget",
                             skipped_at: frozen_time, enrichment_attempts: 3,
                             updated_at: frozen_time)
    end

    it "skips the insert and counts it as a duplicate" do
      tally = write(well_formed_envelope, at: later)

      expect(PushEvent.count).to eq(1)
      expect(tally.to_h).to include(events_created: 0, duplicates_skipped: 1, push_events_seen: 1)
    end

    # §7 merge rule 1: identity may refresh "on any observation, including duplicates".
    it "still refreshes identity fields" do
      write(well_formed_envelope, at: later)

      expect(GithubActor.sole.login).to eq("octocat")
      expect(GithubActor.sole.updated_at).to eq(later)
    end

    # §7 merge rule 3: last_seen_at moves only when RETURNING produced a row. Asserted with
    # a *later* instant, because GREATEST would hide the difference at an equal one.
    it "does not move last_seen_at" do
      write(well_formed_envelope, at: later)

      expect(GithubActor.sole.last_seen_at).to eq(frozen_time)
      expect(GithubRepository.sole.last_seen_at).to eq(frozen_time)
    end

    # first_seen_at uses LEAST, so only an *earlier* replay can discriminate.
    it "does not move first_seen_at" do
      write(well_formed_envelope, at: frozen_time - 60)

      expect(GithubActor.sole.first_seen_at).to eq(frozen_time)
    end

    # §7 merge rule 4, and the whole reason for the gate: "a re-polled window would
    # resurrect skipped entities with no new activity".
    it "cannot reactivate an entity that a budget skip had terminated" do
      write(well_formed_envelope, at: later)

      expect(GithubActor.sole).to have_attributes(
        enrichment_status: "skipped_budget", skipped_at: frozen_time, enrichment_attempts: 3
      )
    end

    # The structural assertion, not just its side effects: the gate is the call site, and
    # both halves of merge rule 3 sit behind it.
    it "never calls the activity update or the reactivation at all" do
      expect(GithubActor).not_to receive(:touch_activity!)
      expect(GithubRepository).not_to receive(:touch_activity!)
      expect(GithubActor).not_to receive(:reactivate_skipped!)
      expect(GithubRepository).not_to receive(:reactivate_skipped!)

      write(well_formed_envelope, at: later)
    end
  end

  # The other side of the same gate, and the pair is the assertion: §7's reactivation rule
  # says "a **newly persisted** push event referencing the entity … may transition it back
  # to pending", while rule 4 says a replay never may. The two examples above and below
  # differ only in whether the event is genuinely new.
  describe "a genuinely new event referencing a skipped entity" do
    let(:later) { frozen_time + 60 }

    before do
      write(well_formed_envelope)

      GithubActor.where(github_id: 583_231)
                 .update_all(enrichment_status: "skipped_budget", skipped_at: frozen_time,
                             enrichment_attempts: 3, updated_at: frozen_time)
      GithubRepository.where(github_id: 1_296_269)
                      .update_all(enrichment_status: "skipped_budget", skipped_at: frozen_time,
                                  updated_at: frozen_time)
    end

    def distinct_event(at:)
      write(well_formed_envelope("id" => "58000000099", "payload" => { "push_id" => 27_500_000_099 }), at: at)
    end

    it "reactivates both entities, because a distinct event id proves new activity" do
      distinct_event(at: later)

      expect(GithubActor.sole).to have_attributes(enrichment_status: "pending", skipped_at: nil)
      expect(GithubRepository.sole).to have_attributes(enrichment_status: "pending", skipped_at: nil)
    end

    # §7's reactivation rule covers delayed-but-new events explicitly: "even with an old
    # created_at (documented 30s-6h latency), a distinct event ID proves new activity".
    it "moves the activity timestamps that drive newest-first ordering" do
      distinct_event(at: later)

      expect(GithubActor.sole.last_seen_at).to eq(later)
    end

    # An inbound envelope performed no fetch, so writing last_error = NULL or resetting the
    # attempt count would assert something that did not happen.
    it "keeps the failure history, because no fetch occurred" do
      distinct_event(at: later)

      expect(GithubActor.sole.enrichment_attempts).to eq(3)
    end

    it "logs the reactivation at INFO, which §11 lists among the enrichment events" do
      allow(Rails.logger).to receive(:info)

      distinct_event(at: later)

      expect(Rails.logger).to have_received(:info)
        .with(hash_including(event: "enrichment.reactivated", github_actor_id: 583_231))
    end

    it "logs nothing when there was nothing to reactivate" do
      GithubActor.update_all(enrichment_status: "pending", skipped_at: nil)
      GithubRepository.update_all(enrichment_status: "pending", skipped_at: nil)
      allow(Rails.logger).to receive(:info)

      distinct_event(at: later)

      expect(Rails.logger).not_to have_received(:info)
        .with(hash_including(event: "enrichment.reactivated"))
    end
  end

  it "absorbs a duplicate that arrives twice within one page" do
    tally = write([ well_formed_envelope, well_formed_envelope ])

    expect(PushEvent.count).to eq(1)
    expect(tally.to_h).to include(events_created: 1, duplicates_skipped: 1, push_events_seen: 2)
  end

  describe "a non-push event" do
    let!(:tally) { write(well_formed_envelope("type" => "WatchEvent")) }

    # §7 row 1: "Ignored and counted — not quarantined."
    it "writes nothing at all, not even stub entities" do
      expect(PushEvent.count).to eq(0)
      expect(QuarantinedEvent.count).to eq(0)
      expect(GithubActor.count).to eq(0)
      expect(GithubRepository.count).to eq(0)
    end

    it "is counted as ignored and not as a push event seen" do
      expect(tally.to_h).to include(events_ignored: 1, push_events_seen: 0, events_quarantined: 0)
    end
  end

  describe "a malformed event" do
    it "quarantines it with its classification and keeps the payload" do
      envelope = well_formed_envelope("payload" => { "head" => nil })

      tally = write(envelope)

      expect(QuarantinedEvent.sole).to have_attributes(
        github_event_id: "58000000001", event_type: "PushEvent",
        error_code: "missing_required_field", occurrence_count: 1,
        first_received_at: received_at, last_received_at: received_at,
        raw_payload: envelope
      )
      expect(tally.to_h).to include(events_quarantined: 1, push_events_seen: 1, events_created: 0)
    end

    it "creates no push event and no stub entities for it" do
      write(well_formed_envelope("payload" => { "head" => nil }))

      expect(PushEvent.count).to eq(0)
      expect(GithubActor.count).to eq(0)
    end

    it "leaves github_event_id and event_type null for an unnameable envelope" do
      write(nil)

      expect(QuarantinedEvent.sole).to have_attributes(
        github_event_id: nil, event_type: nil, error_code: "invalid_envelope", raw_payload: nil
      )
    end

    # §7: the fingerprint is the sole unique key, so the same event id with a different
    # malformed payload is a different row rather than a constraint violation.
    it "gives two envelopes sharing an event id but differing in payload two rows" do
      write([
        well_formed_envelope("payload" => { "head" => nil }),
        well_formed_envelope("payload" => { "head" => nil }, "actor" => { "id" => 999 })
      ])

      expect(QuarantinedEvent.count).to eq(2)
      expect(QuarantinedEvent.pluck(:github_event_id).uniq).to eq([ "58000000001" ])
      expect(QuarantinedEvent.pluck(:occurrence_count)).to all(eq(1))
    end

    # §7's occurrence-count upsert, and the reason events_quarantined counts observations
    # rather than rows.
    it "counts a repeated malformed payload as another occurrence of the same row" do
      write(well_formed_envelope("payload" => { "head" => nil }))
      tally = write(well_formed_envelope("payload" => { "head" => nil }), at: frozen_time + 60)

      expect(QuarantinedEvent.count).to eq(1)
      expect(QuarantinedEvent.sole).to have_attributes(
        occurrence_count: 2, first_received_at: frozen_time, last_received_at: frozen_time + 60
      )
      expect(tally.to_h).to include(events_quarantined: 1)
    end

    # §7: "the first classification of a payload is the one retained."
    it "does not revise the classification of a payload it has already seen" do
      write(well_formed_envelope("payload" => { "head" => nil }))
      QuarantinedEvent.sole.update!(error_code: "improvised")

      write(well_formed_envelope("payload" => { "head" => nil }))

      expect(QuarantinedEvent.sole.error_code).to eq("improvised")
    end
  end

  # §16: "Malformed data is quarantined durably per the taxonomy … and does not terminate
  # the batch." This is the concrete proof, and it only holds because each envelope has its
  # own transaction and quarantine writes outside one.
  describe "an envelope the database refuses" do
    # A String carrying a NUL byte. Verified against PostgreSQL 16 rather than assumed: the
    # driver raises ArgumentError for a text column and PostgreSQL answers
    # PG::UntranslatableCharacter for one inside jsonb. The example asserts the *outcome*
    # rather than the class, so it documents reality instead of an expectation.
    let(:unstorable) { well_formed_envelope("id" => "2", "payload" => { "ref" => "refs/heads/a#{0.chr}b" }) }

    it "counts it as failed without losing the envelopes around it" do
      tally = write([
        well_formed_envelope("id" => "1"),
        well_formed_envelope("id" => "3", "payload" => { "head" => nil }),
        unstorable,
        well_formed_envelope("id" => "4")
      ])

      expect(tally.to_h).to include(events_created: 2, events_failed: 1, events_quarantined: 1)
      expect(PushEvent.pluck(:github_event_id)).to match_array(%w[1 4])
      expect(QuarantinedEvent.count).to eq(1)
    end

    it "writes nothing for the failed envelope itself" do
      write(unstorable)

      expect(PushEvent.count).to eq(0)
      expect(GithubActor.count).to eq(0)
      expect(QuarantinedEvent.count).to eq(0)
    end

    it "counts it as a push event seen, because GitHub still typed it as one" do
      expect(write(unstorable).to_h).to include(push_events_seen: 1, events_failed: 1)
    end

    it "logs the failure with the event id and the error class" do
      allow(Rails.logger).to receive(:error)

      write(unstorable)

      expect(Rails.logger).to have_received(:error).with(
        hash_including(event: "ingestion.event_failed", run_id: run_id, github_event_id: "2")
      )
    end
  end

  # A non-finite Float has no fingerprint, so a malformed envelope carrying one has no
  # quarantine row available to it — the honest outcome is a failure, not an invented
  # identity.
  it "counts an envelope it cannot fingerprint as failed" do
    envelope = well_formed_envelope("payload" => { "head" => nil })
    envelope["payload"]["weight"] = JSON.parse("[1e400]").first

    tally = write(envelope)

    expect(tally.to_h).to include(events_failed: 1, events_quarantined: 0)
    expect(QuarantinedEvent.count).to eq(0)
  end

  # A dead connection is not a property of any one envelope, and a locking invariant is a
  # programming error. Reporting "events_failed: 8, completed" for either would be a lie.
  describe "errors that must not be absorbed" do
    it "re-raises rather than counting them as a failed envelope" do
      described_class::FATAL_ERRORS.each do |error_class|
        writer = described_class.new(registry: exploding_registry(error_class))

        expect { writer.write([ well_formed_envelope ], run_id: run_id) }.to raise_error(error_class)
      end
    end
  end

  describe "counters over the real corpus page" do
    # §12's end-to-end numbers, asserted at the writer level so the integration spec's
    # figures have a unit-level source.
    it "reproduces page 1's expected outcome" do
      tally = write(corpus_page("page-1.json"))

      expect(tally.to_h).to include(
        push_events_seen: 6, events_created: 4, duplicates_skipped: 0,
        events_quarantined: 3, events_ignored: 1, events_failed: 0
      )
      expect(PushEvent.pluck(:github_event_id))
        .to match_array(%w[58000000001 58000000002 58000000003 58000000008])
      expect(GithubActor.pluck(:github_id)).to match_array([ 583_231, 1_024_025, 7_700_421 ])
      expect(GithubRepository.pluck(:github_id)).to match_array([ 1_296_269, 1_300_192, 1_490_033 ])
      expect(QuarantinedEvent.pluck(:error_code))
        .to match_array(%w[missing_required_field invalid_field_format missing_event_type])
    end
  end

  # PushEvent.insert_if_new's comment says reaching its validate! "means the parser let
  # something through". This is the assertion that it cannot: across the whole taxonomy the
  # outcome is a quarantine or a persist, never a validation error.
  it "never hands the model an attribute set it would reject" do
    envelopes = [
      well_formed_envelope,
      well_formed_envelope("id" => nil), well_formed_envelope("actor" => nil),
      well_formed_envelope("repo" => { "name" => "" }), well_formed_envelope("created_at" => "x"),
      well_formed_envelope("payload" => nil), well_formed_envelope("payload" => { "head" => "zz" }),
      well_formed_envelope("payload" => { "repository_id" => 42 }),
      well_formed_envelope("type" => "WatchEvent"), nil, [], "x"
    ]

    tally = write(envelopes)

    expect(tally.events_failed).to eq(0)
    expect(tally.events_created + tally.events_quarantined + tally.events_ignored)
      .to eq(envelopes.length)
  end

  def exploding_registry(error_class)
    instance_double(Github::Events::ProcessorRegistry).tap do |registry|
      allow(registry).to receive(:process).and_raise(error_class)
    end
  end
end
