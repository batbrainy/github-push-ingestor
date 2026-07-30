require "rails_helper"

RSpec.describe Github::EnrichmentSchedule do
  let(:now) { frozen_time }

  # A builder rather than a let, so an example names only the components it is about and
  # every other one is explicitly nil — which is the ordinary state of a freshly stubbed
  # entity against a clean ledger.
  def schedule(**components)
    described_class.new(**described_class::COMPONENTS.index_with { nil }.merge(components))
  end

  describe "the three components (plan §9)" do
    it "names exactly the three §9 lists, in the plan's order" do
      expect(described_class::COMPONENTS)
        .to eq(%i[ next_retry_at global_blocked_until enrichment_class_blocked_until ])
    end

    # §9 licenses --force against cadence_due_at and the stored ETag, "nothing else", and
    # enrichment has no cadence. All three components here are on §9's explicit
    # not-bypassed list, so the absence of a force flag is a structural claim rather than a
    # comment.
    it "takes no force flag, because §9 licenses --force against a poll cadence enrichment has not" do
      expect(described_class.instance_method(:due?).parameters).to eq([ [ :keyreq, :now ] ])
      expect(described_class.constants).not_to include(:FORCEABLE)
    end

    # A share exhaustion is relieved either by the window rolling or by the other class
    # running out of eligible candidates. The second has no instant, and admitting it here
    # would make borrowing unreachable.
    it "carries no per-class share, which is a denial rather than a deferral" do
      expect(described_class.members.grep(/share/)).to be_empty
    end
  end

  describe "#effective_enrichment_time" do
    it "is nil for a freshly stubbed entity against a ledger that constrains nothing" do
      expect(schedule.effective_enrichment_time).to be_nil
    end

    described_class::COMPONENTS.each do |component|
      it "is held back by #{component} alone, so each constraint stands on its own" do
        held = schedule(component => now + 120)

        expect(held.effective_enrichment_time).to eq(now + 120)
        expect(held.binding_component).to eq(component)
      end
    end

    it "takes the latest of several constraints rather than the first one it finds" do
      held = schedule(next_retry_at: now + 60, global_blocked_until: now + 300,
                      enrichment_class_blocked_until: now + 120)

      expect(held.effective_enrichment_time).to eq(now + 300)
      expect(held.binding_component).to eq(:global_blocked_until)
    end

    it "breaks a tie in the plan's order, so the constraint an operator acts on first is named" do
      held = schedule(next_retry_at: now + 60, global_blocked_until: now + 60)

      expect(held.binding_component).to eq(:next_retry_at)
    end

    it "names no binding component when nothing constrains it" do
      expect(schedule.binding_component).to be_nil
    end
  end

  describe "#due?" do
    it "is due when no component applies, which is the ordinary case on a clean checkout" do
      expect(schedule).to be_due(now: now)
    end

    # <= rather than <: PostgreSQL truncates a timestamp to microseconds on the way in and
    # Time.current does not, so a round-tripped next_retry_at can compare unequal to the
    # instant that produced it.
    it "is due at exactly the instant it names" do
      expect(schedule(next_retry_at: now)).to be_due(now: now)
    end

    it "is not due while any component is still in the future" do
      expect(schedule(enrichment_class_blocked_until: now + 1)).not_to be_due(now: now)
    end

    it "is due again once every component has passed" do
      held = schedule(next_retry_at: now - 60, global_blocked_until: now - 1)

      expect(held).to be_due(now: now)
    end
  end

  describe ".for" do
    it "reads the entity's own retry instant and the two ledger components" do
      actor = create_actor(next_retry_at: now + 60)
      create_budget(global_blocked_until: now + 120, enrichment_used: 40,
                    enrichment_allowance: 40, reset_at: now + 3600)

      expect(described_class.for(entity: actor, now: now)).to have_attributes(
        next_retry_at: now + 60, global_blocked_until: now + 120,
        enrichment_class_blocked_until: now + 3600
      )
    end

    # Nothing seeds the ledger row — only a reservation creates it — so a missing one is
    # the ordinary state of a clean checkout rather than an error.
    it "treats a missing ledger row as no constraint rather than as a block" do
      actor = create_actor

      expect(described_class.for(entity: actor, now: now).effective_enrichment_time).to be_nil
    end

    it "does not create the ledger row it reads, because only a reservation may" do
      actor = create_actor

      expect { described_class.for(entity: actor, now: now) }
        .not_to change(GithubApiBudget, :count).from(0)
    end

    it "schedules a repository on the same three components as an actor" do
      repository = create_repository(next_retry_at: now + 90)

      expect(described_class.for(entity: repository, now: now).effective_enrichment_time)
        .to eq(now + 90)
    end

    # §10: "enrichment exhausting its forty attempts never stops polling, and polling
    # exhausting its twelve never stops enrichment." The mirror of this lives in
    # poll_schedule_spec.rb and is structural — PollSchedule reads no enrichment counter.
    it "is unaffected by a spent poll allowance, because one class never stops the other" do
      actor = create_actor
      create_budget(poll_used: 12, poll_allowance: 12, enrichment_used: 0,
                    enrichment_allowance: 40, reset_at: now + 3600)

      expect(described_class.for(entity: actor, now: now)).to be_due(now: now)
    end
  end

  describe "#to_log" do
    it "renders only the components in play, as UTC instants" do
      held = schedule(global_blocked_until: now + 60)

      expect(held.to_log).to eq(global_blocked_until: (now + 60).utc.iso8601)
    end
  end
end
