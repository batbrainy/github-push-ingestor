require "rails_helper"

RSpec.describe Github::Enrichment::Fairness do
  subject(:fairness) { described_class.new(configuration: configuration) }

  let(:configuration) { configuration_with }
  let(:now) { frozen_time }

  def choose(**arguments) = fairness.choose(now: now, **arguments)

  def pending_actor(github_id: 1, **overrides)
    create_actor(github_id: github_id, last_seen_at: now - 60, **overrides)
  end

  def pending_repository(github_id: 2, **overrides)
    create_repository(github_id: github_id, last_seen_at: now - 60, **overrides)
  end

  describe "the conditions that stop all enrichment" do
    it "chooses nothing while a global block is in force" do
      pending_actor
      active_budget_window(now: now, global_blocked_until: now + 60)

      expect(choose).to have_attributes(chosen?: false, reason: "globally_blocked")
    end

    # §7: enrichment is ineligible until the first real poll initializes the window from
    # authoritative headers. Asked here as well as in the ledger so a fresh install reports
    # the honest reason instead of taking the global request gate to be told the same thing.
    it "chooses nothing before the first poll has initialized the window" do
      pending_actor
      Github::BudgetLedger.new.bootstrap!(now: now)

      expect(choose).to have_attributes(chosen?: false, reason: "window_uninitialized")
    end

    it "chooses nothing once the whole enrichment allowance is spent" do
      pending_actor
      active_budget_window(now: now, enrichment_used: 40)

      expect(choose).to have_attributes(chosen?: false, reason: "class_exhausted")
    end

    # Nothing seeds the ledger row, so a clean checkout constrains nothing — the first
    # reservation will create it, and the ledger will refuse there if it must.
    it "still chooses work with no ledger row at all, which the ledger then rules on" do
      pending_actor

      expect(choose).to have_attributes(chosen?: true, reason: "pending")
    end

    it "reports having nothing to do separately from being refused" do
      active_budget_window(now: now)

      expect(choose).to have_attributes(chosen?: false, reason: "no_candidate")
    end
  end

  describe "the pending pools" do
    before { active_budget_window(now: now) }

    it "picks the class that has eligible work" do
      pending_repository

      expect(choose).to have_attributes(entity_type: Github::Enrichment::EntityType.fetch(:repository),
                                        pool: :pending, borrow: false)
    end

    it "breaks a tie toward actors, which is the order EntityType declares" do
      pending_actor
      pending_repository

      expect(choose.entity_type.key).to eq(:actor)
    end

    # §10's whole reason for the split: repository candidates alone exceed the hourly
    # allowance, so a repository-first policy would starve actors to zero indefinitely.
    it "moves to the other class once one has spent its guarantee" do
      pending_actor
      pending_repository
      active_budget_window(now: now, actor_share_used: 20, enrichment_used: 20)

      expect(choose.entity_type.key).to eq(:repository)
    end

    it "restricts to the class a caller named without bypassing anything else" do
      pending_actor
      pending_repository

      expect(choose(entity_class: GithubRepository).entity_type.key).to eq(:repository)
      expect(choose(entity_class: :repository).entity_type.key).to eq(:repository)
    end

    it "refuses a class that has no enrichment counters" do
      expect { choose(entity_class: :organization) }.to raise_error(ArgumentError, /organization/)
    end
  end

  describe "borrowing (plan §10)" do
    before { active_budget_window(now: now, actor_share_used: 20, enrichment_used: 20) }

    # §10: "a class may borrow the other's unused capacity only when the other class has no
    # CURRENTLY ELIGIBLE candidate (not merely no rows)."
    it "borrows when the other class has no eligible candidate" do
      pending_actor

      expect(choose).to have_attributes(entity_type: Github::Enrichment::EntityType.fetch(:actor),
                                        borrow: true, reason: "borrowed_pending")
    end

    it "refuses to borrow while the other class still has eligible work" do
      pending_actor
      pending_repository

      expect(choose).to have_attributes(entity_type: Github::Enrichment::EntityType.fetch(:repository),
                                        borrow: false)
    end

    it "borrows when the other class has rows that are merely ineligible, which is the plan's distinction" do
      pending_actor
      create_repository(github_id: 2, last_seen_at: now - 3601)

      expect(choose).to have_attributes(borrow: true, reason: "borrowed_pending")
    end

    it "does not borrow while the class is still inside its own guarantee" do
      active_budget_window(now: now, actor_share_used: 19, enrichment_used: 19)
      pending_actor

      expect(choose).to have_attributes(borrow: false, reason: "pending")
    end

    it "gives a zero-guarantee class work only by borrowing" do
      starved = described_class.new(configuration: configuration_with(ACTOR_ENRICHMENT_SHARE: "0.0"))
      active_budget_window(now: now)
      pending_actor

      expect(starved.choose(now: now)).to have_attributes(entity_type: Github::Enrichment::EntityType.fetch(:actor),
                                                          borrow: true)
    end
  end

  describe "TTL-stale refreshes" do
    before { active_budget_window(now: now) }

    def stale_actor(github_id: 1)
      create_actor(github_id: github_id, enrichment_status: "complete", fetched_at: now - 90_000,
                   last_seen_at: now - 60)
    end

    # §10: "Within each class, never-enriched pending candidates always precede TTL-stale
    # refreshes — a refresh spends budget only when no pending candidate is currently
    # eligible."
    it "prefers a pending candidate over a stale refresh" do
      stale_actor
      pending_repository

      expect(choose).to have_attributes(entity_type: Github::Enrichment::EntityType.fetch(:repository),
                                        pool: :pending)
    end

    it "offers a refresh only when no class has a pending candidate" do
      stale_actor

      expect(choose).to have_attributes(pool: :refresh, reason: "refresh")
    end

    # §10 scopes the condition globally, so --class actor cannot promote an actor refresh
    # above a repository still waiting to be enriched for the first time.
    it "will not refresh one class while the other still has never-enriched work" do
      stale_actor
      pending_repository

      expect(choose(entity_class: :actor)).to have_attributes(chosen?: false, reason: "no_candidate")
    end

    # With no pending candidate anywhere, "the other class has no currently eligible
    # candidate" is true by definition, so a refresh past the guarantee is a legal borrow.
    it "borrows for a refresh once the class has spent its guarantee" do
      active_budget_window(now: now, actor_share_used: 20, enrichment_used: 20)
      stale_actor

      expect(choose).to have_attributes(pool: :refresh, borrow: true)
    end
  end
end
