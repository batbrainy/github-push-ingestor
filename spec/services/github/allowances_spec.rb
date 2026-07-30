require "rails_helper"

RSpec.describe Github::Allowances do
  def configuration(**overrides)
    Github::Configuration.new(overrides.transform_keys(&:to_s))
  end

  describe "the one authoritative formula (plan §10)" do
    it "derives twelve poll attempts an hour from the pinned defaults" do
      expect(described_class.derive(configuration: configuration, limit: 60).poll_allowance).to eq(12)
    end

    it "derives forty enrichment attempts as limit minus reserve minus polling" do
      expect(described_class.derive(configuration: configuration, limit: 60).enrichment_allowance).to eq(40)
    end

    # A 450-second cadence fits seven whole intervals in an hour plus a remainder, and
    # the eighth poll still happens. Rounding down would under-reserve polling and let
    # enrichment spend the attempt polling needed.
    it "rounds the hourly poll count up, because a partial interval still polls" do
      derived = described_class.derive(configuration: configuration(POLL_INTERVAL_SECONDS: "450"), limit: 60)

      expect(derived.poll_allowance).to eq(8)
    end

    it "multiplies by the page cap, because each page is its own request attempt" do
      derived = described_class.derive(configuration: configuration(MAX_PAGES_PER_POLL: "3"), limit: 60)

      expect(derived.poll_allowance).to eq(36)
    end

    it "multiplies by the enabled live source count, which shares one per-IP budget" do
      derived = described_class.derive(configuration: configuration(ENABLED_LIVE_SOURCE_COUNT: "2"), limit: 60)

      expect(derived.poll_allowance).to eq(24)
    end

    it "reports a negative enrichment allowance rather than hiding an over-commitment" do
      derived = described_class.derive(configuration: configuration(POLL_INTERVAL_SECONDS: "60"), limit: 60)

      expect(derived.enrichment_allowance).to eq(-8)
    end
  end

  describe "#feasible?" do
    it "accepts the pinned defaults, which leave forty enrichment attempts" do
      expect(described_class.derive(configuration: configuration, limit: 60)).to be_feasible
    end

    # Plan §10 rejects on >=, not >: a configuration that leaves exactly zero
    # enrichment capacity cannot satisfy Story 3 either.
    it "rejects a split that leaves exactly zero enrichment capacity" do
      derived = described_class.derive(configuration: configuration(RATE_LIMIT_RESERVE: "48"), limit: 60)

      expect(derived.enrichment_allowance).to eq(0)
      expect(derived).not_to be_feasible
    end

    it "rejects a polling requirement that exceeds the limit outright" do
      expect(described_class.derive(configuration: configuration(POLL_INTERVAL_SECONDS: "60"), limit: 60))
        .not_to be_feasible
    end
  end

  describe "#clamped" do
    it "leaves a feasible derivation untouched" do
      derived = described_class.derive(configuration: configuration, limit: 60)

      expect(derived.clamped).to eq(derived)
    end

    # A live x-ratelimit-limit lower than the configured default is GitHub's business,
    # not an operator error, so runtime degrades instead of crash-looping the worker.
    # Polling wins the clamp because enrichment reaching zero is a documented outcome
    # while polling stopping is a Story 1 failure.
    it "keeps polling whole and gives enrichment what is left when the limit is lower" do
      clamped = described_class.derive(configuration: configuration, limit: 15).clamped

      expect(clamped.poll_allowance).to eq(7)
      expect(clamped.enrichment_allowance).to eq(0)
    end

    it "never derives a negative allowance, which the schema's CHECK would reject" do
      clamped = described_class.derive(configuration: configuration, limit: 4).clamped

      expect(clamped.poll_allowance).to eq(0)
      expect(clamped.enrichment_allowance).to eq(0)
    end

    # The single strongest argument for deriving the guarantees rather than storing them:
    # members computed at .derive would have frozen the pre-clamp numbers into the clamped
    # copy, and -3 actor requests is not a thing the ledger could enforce.
    it "recomputes the guarantees from the clamped allowance rather than from the derived one" do
      derived = described_class.derive(configuration: configuration, limit: 15)

      expect(derived.actor_guarantee).to eq(-3)
      expect(derived.clamped).to have_attributes(actor_guarantee: 0, repository_guarantee: 0)
    end
  end

  describe "the fairness split (plan §10)" do
    def split(allowance, share) = described_class.split(allowance, Rational(share))

    it "splits the pinned defaults into twenty actor and twenty repository attempts" do
      derived = described_class.derive(configuration: configuration, limit: 60)

      expect(derived).to have_attributes(actor_guarantee: 20, repository_guarantee: 20)
    end

    # §10 writes the formula as a floor and a subtraction, so the odd attempt goes to
    # repository by construction. Rounding twice would let the two guarantees miss the
    # total, and the ledger would enforce a cap that does not add up.
    it "gives the odd attempt to repository, because the formula subtracts rather than rounding twice" do
      expect(split(39, "0.5")).to eq(actor: 19, repository: 20)
    end

    it "always sums to the enrichment allowance, whatever the share and whatever the allowance" do
      %w[ 0.0 0.25 0.29 0.5 0.58 0.75 1.0 ].each do |share|
        (0..60).each do |allowance|
          expect(split(allowance, share).values.sum).to eq(allowance),
            "expected share #{share} of #{allowance} to sum to #{allowance}, got #{split(allowance, share).inspect}"
        end
      end
    end

    # The reason Github::Configuration parses the share with Rational rather than Float:
    # (100 * 0.29).floor is 28 in IEEE-754, because 0.29 has no exact binary
    # representation, and an operator would silently lose an attempt off the number they
    # typed.
    it "floors exactly, so a share with no binary representation does not lose an attempt" do
      expect(split(100, "0.29")).to eq(actor: 29, repository: 71)
    end

    it "gives the single attempt of the smallest feasible allowance to repository" do
      expect(split(1, "0.5")).to eq(actor: 0, repository: 1)
    end

    it "leaves the actor class nothing at share zero, which borrowing rather than the split relieves" do
      expect(split(40, "0.0")).to eq(actor: 0, repository: 40)
    end

    it "leaves the repository class nothing at share one" do
      expect(split(40, "1.0")).to eq(actor: 40, repository: 0)
    end

    it "keys the split by request class, so the ledger fetches rather than branching" do
      expect(split(40, "0.5").keys).to match_array(Github::Request::ENRICHMENT_CLASSES)
    end

    # §10's rejection rule is about capacity for Story 3, and one attempt of capacity is
    # one attempt whichever class ends up holding it.
    it "leaves feasibility to the total, so a zero guarantee is not an infeasible configuration" do
      derived = described_class.derive(configuration: configuration(RATE_LIMIT_RESERVE: "47"), limit: 60)

      expect(derived).to be_feasible
      expect(derived).to have_attributes(enrichment_allowance: 1, actor_guarantee: 0, repository_guarantee: 1)
    end

    it "reports both guarantees in the line the ledger logs at window initialization" do
      derived = described_class.derive(configuration: configuration, limit: 60)

      expect(derived.to_log).to include(actor_guarantee: 20, repository_guarantee: 20)
    end
  end
end
