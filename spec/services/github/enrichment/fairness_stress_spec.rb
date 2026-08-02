require "rails_helper"

# Story 3's ninth child issue asks for "starved-class enrichment" to be tested, and §10 says
# what starvation would look like: one observed live page held ~89 distinct actors and ~92
# distinct repositories, so "repository candidates alone exceed the whole hourly allowance,
# and a repo-first policy — or any policy ordering purely by recency across a mixed pool —
# starves actor enrichment to zero indefinitely".
#
# That is a claim about how a *whole window* is distributed, and no single-choice example can
# express it. spec/services/github/enrichment/fairness_spec.rb asks for one choice at a time,
# and budget_ledger_spec.rb and enrichment/end_to_end_spec.rb check the boundaries against
# counters set with update_all. None of them ever spends a window, so none of them can
# observe the property Story 3 actually asks for: that after forty real reservations against
# a twenty-to-one flood, the starved class still got every request it had a candidate for.
#
# The drain drives Fairness, Claim and BudgetLedger directly rather than through
# Github::EnrichmentRunner, and deliberately not through the transport. The corpus resolves
# six entity URLs and its sticky tail would hand every flood row octocat's body, which
# RepositoryDocument.parse then rejects on identity — fifty-seven permanent failures with
# nothing to do with fairness, obscuring the sequence that is the whole point. The three
# objects below are the ones the property lives in, and they are the real ones.
RSpec.describe "enrichment fairness under a flood", type: :integration do
  let(:configuration) { Github.configuration }
  let(:selector) { Github::Enrichment::CandidateSelector.new(configuration: configuration) }
  let(:fairness) { Github::Enrichment::Fairness.new(configuration: configuration, selector: selector) }
  let(:claim) { Github::Enrichment::Claim.new(configuration: configuration, selector: selector) }
  let(:ledger) { Github::BudgetLedger.new(configuration: configuration) }

  # [entity_type_key, borrowed] per granted request, in the order the window granted them.
  let(:sequence) { [] }

  before { active_budget_window(now: frozen_time) }

  # One granted request: choose, lease so the row stops being eligible, debit. Returns the
  # Choice so a caller can assert on a refusal.
  def spend!
    choice = fairness.choose(now: frozen_time)
    return choice unless choice.chosen?

    claim.acquire(choice.entity_type, pool: choice.pool, now: frozen_time)
    ledger.reserve!(choice.entity_type.request_class, now: frozen_time, borrow: choice.borrow)
    sequence << [ choice.entity_type.key, choice.borrow ]

    choice
  end

  def drain!(limit = 60)
    limit.times { break unless spend!.chosen? }
  end

  def flood_repositories(count)
    count.times do |index|
      create_repository(github_id: 300_000 + index, full_name: "flood/repo-#{index}",
                        name: "repo-#{index}", last_seen_at: frozen_time,
                        enrichment_status: "pending")
    end
  end

  def flood_actors(count)
    count.times do |index|
      create_actor(github_id: 400_000 + index, login: "flood-user-#{index}",
                   display_login: "flood-user-#{index}", last_seen_at: frozen_time,
                   enrichment_status: "pending")
    end
  end

  # At the pinned defaults the window is 40 requests split 20/20, so sixty repositories
  # against three actors is §10's ratio with room to spare on one side and none on the other.
  describe "a repository flood, twenty to one" do
    before do
      flood_repositories(60)
      flood_actors(3)
      drain!
    end

    # Story 3's requirement, measured over a window rather than asserted about one choice.
    it "serves all three actor candidates in this finite contention setup" do
      expect(sequence.count { |(key, _)| key == :actor }).to eq(3)
    end

    it "leases every actor it chose, so none of the three was chosen twice" do
      leased = GithubActor.where.not(next_retry_at: nil).count

      expect(leased).to eq(3)
    end

    # A sequence-level property: no per-choice example can state "only after", because the
    # borrow condition is evaluated fresh each time and is legitimately true at the end.
    it "borrows only after the other class has genuinely run dry" do
      first_borrow = sequence.index { |(_, borrow)| borrow }
      last_actor = sequence.rindex { |(key, _)| key == :actor }

      expect(first_borrow).to be > last_actor
    end

    it "records all 40 debits with the two shares summing to the class counter" do
      budget = current_budget

      expect(budget.enrichment_used).to eq(40)
      expect(budget.actor_share_used).to eq(3)
      expect(budget.repository_share_used).to eq(37)
      expect(budget.actor_share_used + budget.repository_share_used).to eq(budget.enrichment_used)
    end

    it "never lets either share exceed the class allowance" do
      budget = current_budget

      expect(budget.actor_share_used).to be <= budget.enrichment_allowance
      expect(budget.repository_share_used).to be <= budget.enrichment_allowance
    end

    it "stops at the allowance rather than one request past it" do
      expect(spend!.reason).to eq("class_exhausted")
      expect(current_budget.enrichment_used).to eq(40)
    end

    # A starved backlog must be *waiting*, not damaged: nothing was charged an attempt and
    # nothing recorded an error, so the rows are exactly as eligible next window as they were
    # this one.
    it "leaves the unenriched backlog intact rather than corrupted" do
      untouched = GithubRepository.where(next_retry_at: nil)

      expect(untouched.count).to eq(60 - 37)
      expect(untouched.pluck(:enrichment_status).uniq).to eq([ "pending" ])
      expect(untouched.pluck(:enrichment_attempts).uniq).to eq([ 0 ])
      expect(untouched.pluck(:last_error).uniq).to eq([ nil ])
    end
  end

  # §10 says "and vice versa", and a floor/remainder split is exactly the kind of arithmetic
  # that works in one direction and is off by one in the other.
  describe "an actor flood, twenty to one" do
    before do
      flood_actors(60)
      flood_repositories(3)
      drain!
    end

    it "serves all three repository candidates in this finite contention setup" do
      expect(sequence.count { |(key, _)| key == :repository }).to eq(3)
    end

    it "holds the flooding class to its guarantee until the other class is quiet" do
      within_guarantee = sequence.count { |(key, borrow)| key == :actor && !borrow }

      expect(within_guarantee).to eq(20)
    end

    # The arithmetic of the drain, not a single boundary: the flooding class takes its
    # twenty, the starved class takes the three it has candidates for, and the remainder is
    # borrowed.
    it "lets the flooding class borrow exactly the remainder" do
      borrowed = sequence.count { |(_, borrow)| borrow }

      expect(borrowed).to eq(40 - 20 - 3)
    end

    it "records all 40 debits with the mirrored share split" do
      budget = current_budget

      expect(budget.enrichment_used).to eq(40)
      expect(budget.actor_share_used).to eq(37)
      expect(budget.repository_share_used).to eq(3)
    end
  end

  describe "class isolation under a real drain" do
    let(:transport) { fixture_transport }

    before do
      flood_repositories(60)
      flood_actors(3)
      drain!
    end

    # The stress direction of Github::RateLimitPolicy's rule that only :reserve_reached, a
    # primary limit and a secondary limit are global. Forty consecutive class-and-share
    # denials wrote nothing global — which is unreachable from any spec that sets the
    # counters with update_all, because there were no denials to write anything.
    it "never writes a global block while denying a whole window of enrichment" do
      spend!
      spend!

      expect(current_budget.global_blocked_until).to be_nil
      expect(current_budget.window_status).to eq("active")
    end

    # The derived-not-stored isolation mechanism, observed after real spending.
    it "blocks the enrichment class and leaves the poll class alone" do
      budget = current_budget

      expect(budget.poll_used).to eq(0)
      expect(budget.poll_class_blocked_until(now: frozen_time)).to be_nil
      expect(budget.enrichment_class_blocked_until(now: frozen_time)).to eq(budget.reset_at)
    end

    it "still polls after enrichment has spent its entire allowance" do
      result = fixture_runner(transport: transport).call(event_source: fixture_event_source)

      expect(result).to be_completed
      expect(current_budget.poll_used).to eq(1)
      expect(PushEvent.count).to eq(4)
    end
  end

  describe "the backlog remains durable under a flood" do
    let(:next_window) { frozen_time + 7200 }

    before do
      flood_repositories(60)
      flood_actors(3)
      active_budget_window(now: frozen_time, enrichment_used: 40)
    end

    it "keeps every entity pending after the exhausted window has passed" do
      expect(GithubRepository.where(enrichment_status: "pending").count).to eq(60)
      expect(GithubActor.where(enrichment_status: "pending").count).to eq(3)
    end

    it "charges no entity attempt when quota exhaustion prevented every request" do
      expect(GithubRepository.distinct.pluck(:enrichment_attempts)).to eq([ 0 ])
      expect(GithubActor.distinct.pluck(:enrichment_attempts)).to eq([ 0 ])
    end

    it "makes the old flood claimable when a later quota window opens" do
      active_budget_window(now: next_window, poll_used: 0, enrichment_used: 0,
                           actor_share_used: 0, repository_share_used: 0)

      expect(fairness.choose(now: next_window)).to be_chosen
    end
  end
end
