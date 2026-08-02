require "rails_helper"

# Appendix F's one-sentence law, asserted rather than assumed: quota delay is never an
# entity outcome. The skipped_budget status and its skipped_at column were removed by
# migration 20260802000000, and nothing may reintroduce them — or any quota-flavored
# terminal value — without failing here first.
#
# Written in the idiom of spec/network_boundary_spec.rb's grep guard: the static half
# scans the code the suite can reach, and the behavioral half proves the property the
# vocabulary implies — a ledger denial, from either ledger, leaves every entity row
# bit-identical.
RSpec.describe "the quota-outcome boundary" do
  describe "the retired skipped_budget state" do
    # Everything executable. Documentation (IMPLEMENTATION_PLAN.md, docs/evidence/) may
    # tell the removal's story; code may not re-live it.
    CODE_GLOBS = %w[
      app/**/*.rb bin/* config/**/*.rb config/**/*.yml db/**/*.rb lib/**/*.rb spec/**/*.rb
    ].freeze

    # Each entry names why the mention is legitimate:
    #   * the two create migrations are frozen history — they built the column the
    #     removal migration later dropped, and rewriting history breaks replays;
    #   * the removal migration and its spec are the removal itself;
    #   * schema_spec and the enrichable_entity shared examples assert the *absence* —
    #     the column gone, the status refused at both the model and the database.
    ALLOWED_MENTIONS = %w[
      db/migrate/20260729210001_create_github_actors.rb
      db/migrate/20260729210002_create_github_repositories.rb
      db/migrate/20260802000000_remove_skipped_budget_from_enrichment.rb
      spec/db/remove_skipped_budget_from_enrichment_spec.rb
      spec/db/schema_spec.rb
      spec/support/shared_examples/enrichable_entity.rb
      spec/quota_outcome_boundary_spec.rb
    ].freeze

    it "appears nowhere in reachable code outside the removal's own history" do
      mentioning = Dir[*CODE_GLOBS.map { |glob| Rails.root.join(glob).to_s }].select do |path|
        File.file?(path) && File.read(path).match?(/skipped_budget|skipped_at/)
      end

      relative = mentioning.map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }

      expect(relative - ALLOWED_MENTIONS).to eq([])
    end
  end

  describe "the entity vocabularies" do
    # A quota denial defers; it never names an entity state. If either list ever grows
    # a member spelled like a budget, the durable-backlog guarantee is being reversed.
    it "contain no quota-flavored value among the statuses" do
      expect(Enrichable::ENRICHMENT_STATUSES.grep(/skip|budget|quota/i)).to eq([])
    end

    it "contain no quota-flavored value among the stages" do
      expect(Enrichable::ENRICHMENT_STAGES.grep(/skip|budget|quota/i)).to eq([])
    end
  end

  # The behavioral half. Both ledgers are spent to their denial thresholds, the real
  # runners attempt both lanes for both classes, and every entity row must come back
  # bit-identical — same status, same stage, same timestamps, same everything. The
  # attempt itself is still evidenced (a deferred enrichment_batches row), because a
  # deferral is an operational fact about the *window*, never about the entity.
  describe "a ledger denial, behaviorally", type: :integration do
    let(:now) { frozen_time }
    let(:configuration) { configuration_with("GITHUB_MODE" => "fixture") }

    # Frozen creation instants, so the release path's updated_at write is provably a
    # restore rather than an unnoticed same-second overwrite.
    let!(:actor) do
      create_actor(github_id: 583_231, last_seen_at: now,
                   created_at: now, updated_at: now)
    end
    let!(:repository) do
      create_repository(github_id: 1_296_269, full_name: "octocat/Hello-World",
                        last_seen_at: now, created_at: now, updated_at: now)
    end

    def entity_fingerprints
      [ actor.reload.attributes, repository.reload.attributes ]
    end

    describe "from the search ledger, with zero headroom" do
      before do
        # used 8 of ceiling 10 with reserve 2: the next reservation is exactly the
        # first one the ceiling refuses.
        active_search_window(now: now, used: 8)
      end

      it "is the admission verdict the cycle would defer on" do
        verdict = Github::Enrichment::Admission.new(configuration: configuration).search(now: now)

        expect(verdict.reason).to eq(:search_ceiling_exhausted)
      end

      it "defers both classes and leaves every entity row bit-identical" do
        before_rows = entity_fingerprints
        runner = fixture_batch_runner(configuration: configuration)

        [ GithubActor, GithubRepository ].each do |entity_class|
          result = runner.call(entity_class: entity_class)

          expect(result.status).to eq("deferred")
          expect(result.deferral_reason).to eq("budget_denied")
        end

        expect(entity_fingerprints).to eq(before_rows)
        expect(current_search_budget.used).to eq(8)
        expect(EnrichmentBatch.where(request_kind: "search").pluck(:status).uniq)
          .to eq([ "deferred" ])
      end
    end

    describe "from the core ledger, with the detail allowance spent" do
      before do
        active_budget_window(now: now, enrichment_used: 4)

        # Rows already admitted to the bounded fallback lane — the shape a search miss
        # leaves behind — with every write frozen at the same instant.
        GithubActor.where(id: actor.id).update_all(
          enrichment_stage: "detail_pending", detail_pending_at: now, updated_at: now
        )
        GithubRepository.where(id: repository.id).update_all(
          enrichment_stage: "detail_pending", detail_pending_at: now, updated_at: now
        )
      end

      it "is the admission verdict the cycle would defer on" do
        verdict = Github::Enrichment::Admission.new(configuration: configuration).detail(now: now)

        expect(verdict.reason).to eq(:class_exhausted)
      end

      it "defers both classes and leaves every entity row bit-identical" do
        before_rows = entity_fingerprints
        runner = fixture_detail_runner(configuration: configuration)

        [ GithubActor, GithubRepository ].each do |entity_class|
          result = runner.call(entity_class: entity_class)

          expect(result.status).to eq("deferred")
          expect(result.reason).to eq("budget_denied")
        end

        expect(entity_fingerprints).to eq(before_rows)
        expect(current_budget.enrichment_used).to eq(4)
        expect(EnrichmentBatch.where(request_kind: "detail").pluck(:status).uniq)
          .to eq([ "deferred" ])
      end
    end
  end
end
