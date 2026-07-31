require "rails_helper"

RSpec.describe Github::EnrichmentRunner do
  subject(:runner) { fixture_enrichment_runner(transport: transport) }

  let(:transport) { fixture_transport }
  let(:now) { frozen_time }

  # The corpus entities page 1 actually produces, so a spec here is a spec about the real
  # payload shape. octocat and Hello-World resolve 200; ghostuser and deleted-org/gone
  # resolve 404, which is what fixtures/github/README.md documents event 8 for.
  def octocat(**overrides)
    create_actor(github_id: 583_231, api_url: "https://api.github.com/users/octocat",
                 last_seen_at: now - 60, **overrides)
  end

  def hello_world(**overrides)
    create_repository(github_id: 1_296_269, full_name: "octocat/Hello-World", name: "Hello-World",
                      api_url: "https://api.github.com/repos/octocat/Hello-World",
                      last_seen_at: now - 60, **overrides)
  end

  def ghostuser(**overrides)
    create_actor(github_id: 7_700_421, login: "ghostuser",
                 api_url: "https://api.github.com/users/ghostuser", last_seen_at: now - 60, **overrides)
  end

  describe "one cycle" do
    before { active_budget_window(now: now) }

    it "enriches one entity and returns one Result describing it" do
      actor = octocat

      result = runner.call

      expect(result).to have_attributes(status: "enriched", entity_type: :actor,
                                        github_id: 583_231, pool: :pending, classification: :ok)
      expect(actor.reload).to have_attributes(enrichment_status: "complete", name: "The Octocat")
    end

    # §5 names EnrichActorJob and EnrichRepositoryJob, so one entity is the unit PR 8 wraps.
    # Batching is the caller's loop, which is what Github::Enrichment::OneShot is.
    it "enriches at most one entity, whatever the backlog" do
      octocat
      hello_world

      runner.call

      expect(GithubActor.complete.count + GithubRepository.complete.count).to eq(1)
    end

    it "debits the class and the share for the entity it chose" do
      octocat

      expect { runner.call }
        .to change { current_budget.actor_share_used }.from(0).to(1)
        .and change { current_budget.enrichment_used }.from(0).to(1)
    end

    it "reports having nothing to do rather than pretending it was refused" do
      expect(runner.call).to have_attributes(status: "idle", deferral_reason: "no_candidate")
    end
  end

  describe "the order of one cycle" do
    before { active_budget_window(now: now) }

    # §12's sequence is "exhaustion → deferred → skipped_budget → reactivation", which
    # requires skipping to keep happening *while* the budget is exhausted — precisely when
    # boundedness matters. Behind the fairness decision it would stop exactly then.
    it "ages out overdue candidates before it asks whether it may spend" do
      aged = octocat(last_seen_at: now - 3601)
      active_budget_window(now: now, enrichment_used: 40)

      result = runner.call

      expect(result).to have_attributes(status: "deferred", deferral_reason: "class_exhausted", aged_out: 1)
      expect(aged.reload.enrichment_status).to eq("skipped_budget")
    end

    it "sweeps on every cycle, including the ones that enrich something" do
      octocat
      create_actor(github_id: 999, last_seen_at: now - 3601)

      expect(runner.call.aged_out).to eq(1)
    end
  end

  describe "deferrals" do
    # §12 line 981's first step. The entity is untouched and stays in the pool; it becomes
    # skipped_budget only later, through the sweep, when its own activity ages out.
    it "returns deferred without touching the entity when the class allowance is gone" do
      actor = octocat
      active_budget_window(now: now, enrichment_used: 40)
      before = actor.reload.attributes

      expect(runner.call).to have_attributes(status: "deferred", deferral_reason: "class_exhausted")
      expect(actor.reload.attributes).to eq(before)
    end

    it "returns deferred while a global block is in force" do
      octocat
      active_budget_window(now: now, global_blocked_until: now + 60)

      expect(runner.call).to have_attributes(status: "deferred", deferral_reason: "globally_blocked")
    end

    # §7: enrichment is ineligible until the first real poll initializes the window from
    # authoritative headers — "never assume 60 remaining".
    it "returns deferred before any poll has initialized the window" do
      octocat
      Github::BudgetLedger.new.bootstrap!(now: now)

      expect(runner.call).to have_attributes(status: "deferred", deferral_reason: "window_uninitialized")
    end

    it "spends nothing on a deferred cycle" do
      octocat
      active_budget_window(now: now, enrichment_used: 40)

      expect { runner.call }.not_to change { current_budget.enrichment_used }.from(40)
    end
  end

  describe "the guarantees §5 and §8 make structurally" do
    before { active_budget_window(now: now) }

    # §8 step 1: "Enrichment jobs skip this step — they take only the request gate."
    it "never acquires a source lock, because enrichment belongs to no event source" do
      octocat
      expect(Github::SourceLock).not_to receive(:acquire)

      runner.call
    end

    # BudgetLedger#assert_committable! raises inside a joinable application transaction, and
    # every enrichment attempt goes through the executor — so this passing at all is the
    # assertion that nothing wrapped the fetch.
    it "opens no transaction across the GitHub request" do
      octocat

      expect(runner.call.status).to eq("enriched")
    end

    # §10: "Never disable the event source because one enrichment target disappeared."
    it "records a permanent failure without disabling the event source" do
      ghostuser
      source = fixture_event_source

      result = runner.call

      expect(result).to have_attributes(status: "failed", classification: :not_found)
      expect(GithubActor.find_by(github_id: 7_700_421).enrichment_status).to eq("permanent_failure")
      expect(source.reload).to have_attributes(status: "idle", enabled: true)
    end

    # The executor validates before the gate specifically so an SSRF-violating enrichment
    # URL never debits budget — §10's "violations mark the entity permanent_failure",
    # satisfied by the chain that already exists rather than by a special case here.
    it "spends no budget on a URL-policy violation, and still marks the entity permanently failed" do
      actor = octocat(api_url: "https://evil.example.com/users/octocat")

      result = runner.call

      expect(result).to have_attributes(status: "failed", classification: :permanent_error)
      expect(actor.reload.enrichment_status).to eq("permanent_failure")
      expect(current_budget.enrichment_used).to eq(0)
    end

    it "treats an entity with no API URL the same way, with no special case anywhere" do
      actor = octocat(api_url: nil)

      runner.call

      expect(actor.reload.enrichment_status).to eq("permanent_failure")
      expect(current_budget.enrichment_used).to eq(0)
    end
  end

  describe "the borrow it asserts to the ledger" do
    it "asks to borrow when the other class has no eligible candidate" do
      octocat
      active_budget_window(now: now, actor_share_used: 20, enrichment_used: 20)

      expect(runner.call).to have_attributes(status: "enriched", borrow: true)
      expect(current_budget.actor_share_used).to eq(21)
    end

    it "does not ask to borrow while the other class still has work" do
      octocat
      hello_world
      active_budget_window(now: now, actor_share_used: 20, enrichment_used: 20)

      expect(runner.call).to have_attributes(entity_type: :repository, borrow: false)
    end
  end

  describe "restricting to one class" do
    before { active_budget_window(now: now) }

    it "enriches only the class it was given" do
      octocat
      hello_world

      expect(runner.call(entity_class: GithubRepository).entity_type).to eq(:repository)
    end

    # --class narrows selection; §10's constraints are all still in force.
    it "still obeys the budget, so restricting a class cannot spend an allowance that is gone" do
      octocat
      active_budget_window(now: now, enrichment_used: 40)

      expect(runner.call(entity_class: GithubActor).status).to eq("deferred")
    end
  end

  describe "errors it refuses to launder" do
    before { active_budget_window(now: now) }

    # §6: "if a URL is not present in the corpus, a fixture error is raised". A corpus gap
    # is an authoring bug, and turning it into a plausible-looking entity failure would let
    # a deterministic demo report the wrong thing.
    it "releases the lease and re-raises on a corpus gap, costing the entity no attempt" do
      actor = octocat(api_url: "https://api.github.com/users/not-in-the-corpus")
      before = actor.reload.attributes

      expect { runner.call }.to raise_error(Github::Errors::FixtureMiss)
      expect(actor.reload.attributes).to eq(before)
    end
  end

  describe "logging (plan §11)" do
    before { active_budget_window(now: now) }

    it "logs a completed enrichment at INFO with the entity and its classification" do
      octocat
      allow(Rails.logger).to receive(:info)

      runner.call

      expect(Rails.logger).to have_received(:info).with(
        hash_including(event: "enrichment.completed", entity_type: :actor, github_id: 583_231,
                       classification: :ok, entity_status: "complete")
      )
    end

    it "logs a failure at INFO with the error and the scheduled retry" do
      ghostuser
      allow(Rails.logger).to receive(:info)

      runner.call

      expect(Rails.logger).to have_received(:info)
        .with(hash_including(event: "enrichment.failed", entity_status: "permanent_failure"))
    end

    # Under PR 8's recurring task an exhausted window would otherwise emit a line a minute
    # for the rest of the hour — the volume argument BudgetLedger#log_class_exhausted makes.
    it "keeps a deferral at DEBUG, so an exhausted window does not bury the stream" do
      octocat
      active_budget_window(now: now, enrichment_used: 40)
      allow(Rails.logger).to receive(:info)
      allow(Rails.logger).to receive(:debug)

      runner.call

      expect(Rails.logger).to have_received(:debug).with(hash_including(event: "enrichment.deferred"))
      expect(Rails.logger).not_to have_received(:info).with(hash_including(event: "enrichment.deferred"))
    end

    # §11's common-field list includes the attempt number, and this is the line §11 actually
    # asks reviewers to read. lease.to_log already carried it onto the DEBUG request line,
    # so it was present exactly where nobody was looking and absent where they were.
    it "carries §11's attempt number onto the outcome line, not only onto the request line" do
      ghostuser(enrichment_attempts: 1)
      allow(Rails.logger).to receive(:info)

      runner.call

      expect(Rails.logger).to have_received(:info).with(
        hash_including(event: "enrichment.failed", enrichment_attempt: 2,
                       entity_status: "permanent_failure")
      )
    end

    it "counts the attempt from zero on an entity that has never been fetched" do
      octocat
      allow(Rails.logger).to receive(:info)

      runner.call

      expect(Rails.logger).to have_received(:info)
        .with(hash_including(event: "enrichment.completed", enrichment_attempt: 1))
    end

    # Result::EVENTS owns "enrichment.failed" for the ordinary outcome §11 lists — INFO,
    # with an entity status and a scheduled retry. An escaped exception has a released
    # lease, an error pair and no entity outcome at all, so sharing the name would make one
    # alert match two structurally different records.
    it "reports an escaped exception under its own name, not the outcome's" do
      octocat
      allow(Rails.logger).to receive(:error)
      exploding = instance_double(Github::Enrichment::EntityState)
      allow(exploding).to receive(:record!).and_raise(RuntimeError, "boom")

      expect { fixture_enrichment_runner(transport: transport, entity_state: exploding).call }
        .to raise_error(RuntimeError, "boom")

      expect(Rails.logger).to have_received(:error).with(
        hash_including(event: "enrichment.cycle_failed", entity_type: :actor,
                       error_class: "RuntimeError", error_message: "boom")
      )
      expect(Rails.logger).not_to have_received(:error)
        .with(hash_including(event: "enrichment.failed"))
    end
  end
end
