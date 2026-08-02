require "rails_helper"

RSpec.describe Github::Allowances do
  def configuration(**overrides)
    Github::Configuration.new(overrides.transform_keys(&:to_s))
  end

  describe "the one authoritative formula (plan §10, Appendix F)" do
    it "derives twelve poll attempts an hour from the pinned defaults" do
      expect(described_class.derive(configuration: configuration, limit: 60).poll_allowance).to eq(12)
    end

    # Appendix G: the detail-fallback allowance is a configured cap, not the remainder
    # of the limit. Search batches carry the enrichment volume on their own per-minute
    # ledger, so the core budget funds only the per-entity fallback fetches — the whole
    # remainder after polling and the reserve, spent on the Search-miss residue.
    it "takes the configured detail-fallback allowance rather than deriving it from the limit" do
      expect(described_class.derive(configuration: configuration, limit: 60).enrichment_allowance).to eq(40)
    end

    it "keeps that allowance fixed whatever limit GitHub reports" do
      expect(described_class.derive(configuration: configuration, limit: 5000).enrichment_allowance).to eq(40)
    end

    it "reads CORE_DETAIL_FALLBACK_ALLOWANCE, so the cap is an operator's number" do
      derived = described_class.derive(
        configuration: configuration(CORE_DETAIL_FALLBACK_ALLOWANCE: "6"), limit: 60
      )

      expect(derived.enrichment_allowance).to eq(6)
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

    # The allowance is configured, so an over-committed cadence no longer shows up as a
    # negative allowance — the derivation stays honest and #feasible? carries the verdict.
    it "keeps the configured allowance under an over-committed cadence, leaving #feasible? the verdict" do
      derived = described_class.derive(configuration: configuration(POLL_INTERVAL_SECONDS: "60"), limit: 60)

      expect(derived.enrichment_allowance).to eq(40)
      expect(derived).not_to be_feasible
    end
  end

  describe "#feasible?" do
    it "accepts the pinned defaults, which commit the whole limit" do
      expect(described_class.derive(configuration: configuration, limit: 60)).to be_feasible
    end

    # Appendix F's predicate is poll + reserve + allowance <= limit: every configured
    # number is a real commitment now, so a sum that lands exactly on the limit is a
    # fully-funded plan rather than a starved one.
    it "accepts the exact boundary, where the three commitments fill the limit precisely" do
      derived = described_class.derive(
        configuration: configuration(RATE_LIMIT_RESERVE: "44", CORE_DETAIL_FALLBACK_ALLOWANCE: "4"),
        limit: 60
      )

      expect(derived.poll_allowance + derived.reserve + derived.enrichment_allowance).to eq(60)
      expect(derived).to be_feasible
    end

    it "rejects the first sum past the limit" do
      expect(described_class.derive(
        configuration: configuration(RATE_LIMIT_RESERVE: "45", CORE_DETAIL_FALLBACK_ALLOWANCE: "4"),
        limit: 60
      )).not_to be_feasible
    end

    # Detail fallback is the exception path behind search batches, so an operator may
    # turn it off outright; the batch lane still enriches on its own ledger.
    it "accepts a zero detail-fallback allowance as a legal operating point" do
      derived = described_class.derive(
        configuration: configuration(CORE_DETAIL_FALLBACK_ALLOWANCE: "0"), limit: 60
      )

      expect(derived).to be_feasible
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
    # Polling wins the clamp because detail fallback reaching zero is a documented outcome
    # while polling stopping is a Story 1 failure.
    it "keeps polling first and gives detail fallback what is left when the limit is lower" do
      clamped = described_class.derive(configuration: configuration, limit: 15).clamped

      expect(clamped.poll_allowance).to eq(7)
      expect(clamped.enrichment_allowance).to eq(0)
    end

    it "funds part of the allowance when the limit covers polling and some fallback" do
      clamped = described_class.derive(configuration: configuration, limit: 22).clamped

      expect(clamped.poll_allowance).to eq(12)
      expect(clamped.enrichment_allowance).to eq(2)
    end

    # The allowance is a cap, not a remainder: spendable headroom above it belongs to
    # nobody. Raising it to the leftover would silently turn a generous observed limit
    # into detail-fallback spending the operator never asked for.
    it "never raises the allowance above its configured cap, however much headroom the limit leaves" do
      clamped = described_class.derive(configuration: configuration, limit: 5000).clamped

      expect(clamped.enrichment_allowance).to eq(40)
    end

    it "never derives a negative allowance, which the schema's CHECK would reject" do
      clamped = described_class.derive(configuration: configuration, limit: 4).clamped

      expect(clamped.poll_allowance).to be >= 0
      expect(clamped.enrichment_allowance).to eq(0)
    end

    # The clamp's floor, and the reason it is not cosmetic. A limit at or below the reserve
    # leaves nothing spendable, and a poll allowance of zero is unrecoverable: every poll is
    # denied :class_allowance_exhausted, only a poll can observe a new x-ratelimit-limit,
    # and rollover re-derives from the stored one — which nothing can now change.
    it "keeps one poll attempt when the limit is at or below the reserve, or nothing recovers" do
      clamped = described_class.derive(configuration: configuration, limit: 4).clamped

      expect(clamped.poll_allowance).to eq(1)
      expect(clamped.enrichment_allowance).to eq(0)
    end

    it "keeps that one attempt even when the reserve alone exceeds the whole limit" do
      clamped = described_class.derive(configuration: configuration(RATE_LIMIT_RESERVE: "80"), limit: 60).clamped

      expect(clamped).to have_attributes(poll_allowance: 1, enrichment_allowance: 0)
    end

    # The single strongest argument for deriving the guarantees rather than storing them:
    # members computed at .derive would have frozen the pre-clamp 2/2 into the clamped
    # copy, and the ledger would enforce guarantees the clamped allowance cannot fund.
    it "recomputes the guarantees from the clamped allowance rather than from the derived one" do
      derived = described_class.derive(configuration: configuration, limit: 15)

      expect(derived).to have_attributes(actor_guarantee: 20, repository_guarantee: 20)
      expect(derived.clamped).to have_attributes(actor_guarantee: 0, repository_guarantee: 0)
    end
  end

  describe "the fairness split (plan §10)" do
    def split(allowance, share) = described_class.split(allowance, Rational(share))

    it "splits the pinned defaults into twenty actor and twenty repository fallback attempts" do
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

    it "gives the single attempt of the smallest allowance to repository" do
      expect(split(1, "0.5")).to eq(actor: 0, repository: 1)
    end

    it "leaves the actor class nothing at share zero, which borrowing rather than the split relieves" do
      expect(split(40, "0.0")).to eq(actor: 0, repository: 40)
    end

    it "leaves the repository class nothing at share one" do
      expect(split(40, "1.0")).to eq(actor: 40, repository: 0)
    end

    # Keyed by the two detail classes: only :actor and :repository spend core detail
    # fallback, while the search pair debits its own per-minute ledger with no share.
    it "keys the split by detail request class, so the ledger fetches rather than branching" do
      expect(split(40, "0.5").keys).to match_array(Github::Request::DETAIL_CLASSES)
    end

    # Feasibility is about the total, and one attempt of capacity is one attempt of
    # capacity whichever class ends up holding it — a zero guarantee is relieved by
    # borrowing, not by rejecting the configuration.
    it "leaves feasibility to the total, so a zero guarantee is not an infeasible configuration" do
      derived = described_class.derive(
        configuration: configuration(CORE_DETAIL_FALLBACK_ALLOWANCE: "1"), limit: 60
      )

      expect(derived).to be_feasible
      expect(derived).to have_attributes(enrichment_allowance: 1, actor_guarantee: 0, repository_guarantee: 1)
    end

    it "reports both guarantees in the line the ledger logs at window initialization" do
      derived = described_class.derive(configuration: configuration, limit: 60)

      expect(derived.to_log).to include(actor_guarantee: 20, repository_guarantee: 20)
    end
  end
end
