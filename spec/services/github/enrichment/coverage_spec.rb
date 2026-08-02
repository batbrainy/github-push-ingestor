require "rails_helper"

RSpec.describe Github::Enrichment::Coverage do
  # Time.current rather than frozen_time: the window is relative to `now`, and every
  # example places its rows against the same instant it passes in.
  let(:now) { Time.current }

  def configuration_with(**overrides)
    Github::Configuration.new(overrides.transform_keys(&:to_s))
  end

  def capture(**overrides)
    described_class.capture(now: now, configuration: configuration_with(**overrides))
  end

  # created_at defaults to inside the window; occurred_at is set independently so the two
  # basis-discriminating examples below can pull them apart.
  def event(id, actor:, repository:, created_at: now - 60, occurred_at: now - 60)
    create_push_event(actor: actor, repository: repository, github_event_id: id,
                      created_at: created_at, occurred_at: occurred_at)
  end

  let(:actor) { create_actor(github_id: 1001) }
  let(:repository) { create_repository(github_id: 2001) }

  describe "the window basis (plan §11)" do
    # The two examples that stop a later refactor silently changing what the metric means.
    # created_at >= occurred_at always, so these are the only two rows that can distinguish
    # the bases, and each one alone would pass under either.
    it "includes an event that occurred long ago but was persisted inside the window" do
      event("40000000001", actor: actor, repository: repository,
            occurred_at: now - 100_000, created_at: now - 60)

      expect(capture.event_count).to eq(1)
    end

    it "excludes an event that occurred inside the window but was persisted before it" do
      event("40000000001", actor: actor, repository: repository,
            occurred_at: now - 60, created_at: now - 100_000)

      expect(capture.event_count).to eq(0)
    end

    it "names the basis in the payload rather than leaving the consumer to infer it" do
      expect(capture.payload[:basis]).to eq("created_at")
    end

    it "reads the window from the configuration it was given" do
      event("40000000001", actor: actor, repository: repository, created_at: now - 600)

      expect(capture(ENRICHMENT_COVERAGE_WINDOW_SECONDS: "3600").event_count).to eq(1)
      expect(capture(ENRICHMENT_COVERAGE_WINDOW_SECONDS: "60").event_count).to eq(0)
    end
  end

  describe "the three formulas (plan §11)" do
    # An actor referenced by many events is one actor on both sides of its own ratio, while
    # the event ratio counts rows. Without COUNT(DISTINCT …) the entity denominator would
    # be the event count and every percentage would be wrong in the same direction.
    it "counts an entity once however many events reference it" do
      3.times { |n| event("4000000000#{n}", actor: actor, repository: repository) }

      expect(capture).to have_attributes(event_count: 3, actor_count: 1, repository_count: 1)
    end

    it "reports a fully enriched window as complete on all three" do
      actor.update!(enrichment_status: "complete", fetched_at: now)
      repository.update!(enrichment_status: "complete", fetched_at: now)
      event("40000000001", actor: actor, repository: repository)

      expect(capture).to have_attributes(actor_coverage_pct: 100.0,
                                         repository_coverage_pct: 100.0,
                                         events_with_both_entities_enriched_pct: 100.0)
    end

    # The third formula is not the product or the minimum of the other two — it is a
    # per-event conjunction, and this is the arrangement that tells them apart.
    it "counts an event only when both of its entities are complete" do
      actor.update!(enrichment_status: "complete", fetched_at: now)
      event("40000000001", actor: actor, repository: repository)

      expect(capture).to have_attributes(actor_coverage_pct: 100.0,
                                         repository_coverage_pct: 0.0,
                                         both_complete_event_count: 0,
                                         events_with_both_entities_enriched_pct: 0.0)
    end

    it "counts only complete, not the other three statuses" do
      %w[pending retryable_failure permanent_failure].each_with_index do |status, n|
        other = create_actor(github_id: 3000 + n, login: "user#{n}")
        other.update!(enrichment_status: status)
        event("4000000010#{n}", actor: other, repository: repository)
      end

      expect(capture).to have_attributes(actor_count: 3, complete_actor_count: 0,
                                         actor_coverage_pct: 0.0)
    end

    it "rounds to the second decimal, which is the decimal the sampling rate moves" do
      complete = create_actor(github_id: 1002, login: "enriched")
      complete.update!(enrichment_status: "complete", fetched_at: now)
      event("40000000001", actor: complete, repository: repository)
      2.times do |n|
        other = create_actor(github_id: 4000 + n, login: "other#{n}")
        event("4000000020#{n}", actor: other, repository: repository)
      end

      expect(capture.actor_coverage_pct).to eq(33.33)
    end
  end

  describe "an empty window" do
    # §16 forbids the fabricated zero. 0.0 here would read as "nothing is enriched" when
    # the truth is "there is nothing in the window to enrich", and those are different
    # facts an operator acts on differently. The denominator is published beside the ratio,
    # so nil is self-explanatory.
    it "reports no percentage rather than a zero one" do
      expect(capture).to have_attributes(actor_coverage_pct: nil,
                                         repository_coverage_pct: nil,
                                         events_with_both_entities_enriched_pct: nil)
    end

    it "still reports every count, because a counted zero is a fact" do
      expect(capture).to have_attributes(event_count: 0, actor_count: 0,
                                         complete_actor_count: 0, repository_count: 0,
                                         complete_repository_count: 0,
                                         both_complete_event_count: 0)
    end

    it "publishes a fixed key set, so a client never handles two shapes" do
      event("40000000001", actor: actor, repository: repository)
      populated = capture.payload

      expect(capture(ENRICHMENT_COVERAGE_WINDOW_SECONDS: "1").payload.keys)
        .to eq(populated.keys)
    end
  end

  describe "the structural guarantees §11 places on the read path" do
    # The literal is interpolated into SQL rather than bound, so this pins it against the
    # enum: a renamed status must not leave the filter matching a value that is gone.
    it "pins its complete literal to the entity state machine" do
      expect(Enrichable::ENRICHMENT_STATUSES).to include(described_class::COMPLETE)
    end

    it "initiates no GitHub request" do
      transport = fixture_transport
      allow(Github).to receive(:transport).and_return(transport)
      expect(Github).not_to receive(:executor)

      capture

      expect(transport.requests).to be_empty
    end

    # The subtler mistake this catches is reaching Github::BudgetLedger#bootstrap! from a
    # read path. This class should not touch the ledger at all.
    it "does not create the ledger row" do
      expect { capture }.not_to change(GithubApiBudget, :count).from(0)
    end
  end
end
