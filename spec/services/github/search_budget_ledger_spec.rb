require "rails_helper"

RSpec.describe Github::SearchBudgetLedger do
  subject(:ledger) { described_class.new }

  # GitHub's Search window is one minute, not core's hour — the whole reason this
  # ledger exists as a separate row (Appendix F).
  let(:window_reset) { frozen_time + 60 }

  # Both defined in spec/support/budget_helpers.rb, so "what an active search window
  # looks like" is stated once and the executor's specs use the same definition.
  def budget = current_search_budget
  def active_window(**overrides) = active_search_window(**overrides)

  def snapshot(**overrides)
    Github::RateLimitSnapshot.from_headers({
      "x-ratelimit-resource" => "search", "x-ratelimit-limit" => "10",
      "x-ratelimit-remaining" => "9", "x-ratelimit-reset" => window_reset.to_i.to_s
    }.merge(overrides.transform_keys(&:to_s)), observed_at: frozen_time)
  end

  describe "#bootstrap!" do
    # Unlike the core ledger, the search row self-initializes from configuration: the
    # ceiling/reserve pair is a configured budget, not something a response teaches us.
    it "creates the singleton row from the configured ceiling and reserve" do
      expect { ledger.bootstrap!(now: frozen_time) }.to change(GithubSearchBudget, :count).from(0).to(1)

      expect(budget).to have_attributes(
        request_ceiling: 10, reserve: 2, used: 0, actor_used: 0, repository_used: 0,
        limit: nil, remaining: nil, reset_at: nil, blocked_until: nil, last_request_at: nil
      )
    end

    # Two processes starting cold race here; insert_all's unique_by makes the loser a
    # no-op rather than a RecordNotUnique that would poison a transaction.
    it "tolerates a row another process created first" do
      ledger.bootstrap!(now: frozen_time)

      expect { ledger.bootstrap!(now: frozen_time) }.not_to change(GithubSearchBudget, :count)
    end

    it "never overwrites a live row's counters, because bootstrap is not a reset" do
      active_window(used: 5, actor_used: 5)

      ledger.bootstrap!(now: frozen_time)

      expect(budget).to have_attributes(used: 5, actor_used: 5)
    end
  end

  describe "#reserve!" do
    it "debits the shared counter and the actor lane, and stamps the pacing instant" do
      active_window

      ledger.reserve!(:actor_search, now: frozen_time)

      expect(budget).to have_attributes(used: 1, actor_used: 1, repository_used: 0,
                                        last_request_at: frozen_time)
    end

    it "debits the repository lane for its own class" do
      active_window

      ledger.reserve!(:repository_search, now: frozen_time)

      expect(budget).to have_attributes(used: 1, actor_used: 0, repository_used: 1)
    end

    it "decrements the local remaining estimate, so a failure is spent against it too" do
      active_window(remaining: 9)

      expect { ledger.reserve!(:actor_search, now: frozen_time) }
        .to change { budget.remaining }.from(9).to(8)
    end

    it "leaves an unobserved remaining null rather than collapsing it to zero" do
      active_window(remaining: nil)

      ledger.reserve!(:actor_search, now: frozen_time)

      expect(budget.remaining).to be_nil
    end

    it "creates the ledger row on first use, so a cold start needs no seeding step" do
      expect { ledger.reserve!(:actor_search, now: frozen_time) }
        .to change(GithubSearchBudget, :count).from(0).to(1)
    end

    # Borrowing is a core-ledger fairness concept: the search lanes share one ceiling
    # and the LaneSchedule rotates them, so "spend past your guarantee" has no meaning
    # here. Accepting the flag silently would let a caller believe it was honoured.
    it "refuses a borrow as a programming error, not a denial" do
      active_window

      expect { ledger.reserve!(:actor_search, now: frozen_time, borrow: true) }
        .to raise_error(ArgumentError, /borrow/)
    end

    it "refuses a non-search request class rather than debiting nothing silently" do
      active_window

      %i[ poll actor repository ].each do |request_class|
        expect { ledger.reserve!(request_class, now: frozen_time) }
          .to raise_error(ArgumentError, /#{request_class}/)
      end
    end
  end

  # The order is diagnostic, not arbitrary: each reason names the condition an operator
  # should look at first. A blocked ledger must say "blocked" even when it is also
  # paced, past its reserve, and out of ceiling.
  describe "the denial order" do
    def reason_for_reservation
      ledger.reserve!(:actor_search, now: frozen_time)
      nil
    rescue Github::Errors::BudgetExhausted => error
      error.reason
    end

    it "names the block first, whatever else is also true" do
      active_window(blocked_until: frozen_time + 30, last_request_at: frozen_time,
                    remaining: 2, used: 8)

      expect(reason_for_reservation).to eq(:search_blocked)
    end

    it "names pacing once the block has passed" do
      active_window(blocked_until: frozen_time - 1, last_request_at: frozen_time - 1,
                    remaining: 2, used: 8)

      expect(reason_for_reservation).to eq(:search_pacing)
    end

    it "names the reserve once pacing has elapsed" do
      active_window(last_request_at: frozen_time - 60, remaining: 2, used: 8)

      expect(reason_for_reservation).to eq(:search_reserve_reached)
    end

    it "names the ceiling when only the local counter is exhausted" do
      active_window(remaining: nil, used: 8)

      expect(reason_for_reservation).to eq(:search_ceiling_exhausted)
    end

    it "raises Errors::BudgetExhausted carrying the class and the reason" do
      active_window(blocked_until: frozen_time + 30)

      expect { ledger.reserve!(:repository_search, now: frozen_time) }
        .to raise_error(Github::Errors::BudgetExhausted) do |error|
          expect(error.request_class).to eq(:repository_search)
          expect(error.reason).to eq(:search_blocked)
        end
    end

    it "spends nothing when it denies, so a refused reservation costs no quota" do
      active_window(remaining: nil, used: 8)

      expect { suppress(Github::Errors::BudgetExhausted) { ledger.reserve!(:actor_search, now: frozen_time) } }
        .not_to change { budget.used }.from(8)
    end

    # The spendable boundary: ceiling 10 minus reserve 2 leaves 8, so the eighth
    # request is granted and the ninth is not.
    it "grants right up to ceiling minus reserve and refuses the next" do
      active_window(remaining: nil, used: 7)

      expect { ledger.reserve!(:actor_search, now: frozen_time) }.not_to raise_error
      expect { ledger.reserve!(:actor_search, now: frozen_time + 30) }
        .to raise_error(Github::Errors::BudgetExhausted, /search_ceiling_exhausted/)
    end

    it "grants while the observed remaining still clears the reserve" do
      active_window(remaining: 3)

      expect { ledger.reserve!(:actor_search, now: frozen_time) }.not_to raise_error
    end

    it "names only the documented denial reasons" do
      expect(described_class::DENIAL_REASONS)
        .to contain_exactly(:search_blocked, :search_pacing, :search_reserve_reached,
                            :search_ceiling_exhausted)
    end
  end

  describe "pacing" do
    it "defers a reservation inside the pacing interval" do
      active_window(last_request_at: frozen_time - 3)

      expect { ledger.reserve!(:actor_search, now: frozen_time) }
        .to raise_error(Github::Errors::BudgetExhausted, /search_pacing/)
    end

    it "grants again exactly one pacing interval after the last request" do
      active_window(last_request_at: frozen_time - 6)

      expect { ledger.reserve!(:actor_search, now: frozen_time) }.not_to raise_error
    end

    # SEARCH_PACING_SECONDS=0 is a documented operating point (the offline fixture
    # walkthrough runs both lanes back to back), so zero must mean "no pacing" and not
    # "deny everything".
    it "disables pacing entirely at SEARCH_PACING_SECONDS=0" do
      unpaced = described_class.new(configuration: configuration_with(SEARCH_PACING_SECONDS: "0"))
      active_window

      unpaced.reserve!(:actor_search, now: frozen_time)

      expect { unpaced.reserve!(:actor_search, now: frozen_time) }.not_to raise_error
      expect(budget.used).to eq(2)
    end
  end

  describe "window rollover" do
    it "resets the counters and header state when GitHub's reset instant has passed" do
      active_window(used: 8, actor_used: 5, repository_used: 3, remaining: 2,
                    blocked_until: window_reset - 10)

      ledger.reserve!(:actor_search, now: window_reset + 1)

      expect(budget).to have_attributes(used: 1, actor_used: 1, repository_used: 0,
                                        remaining: nil, reset_at: nil, blocked_until: nil)
    end

    # A dead window's remaining of 2 against a reserve of 2 would otherwise deny every
    # search forever — the search analogue of the core ledger's stale-remaining deadlock.
    it "clears a stale remaining that would otherwise pin the ledger at its reserve" do
      active_window(remaining: 2)

      expect { ledger.reserve!(:actor_search, now: window_reset + 1) }.not_to raise_error
      expect(budget.remaining).to be_nil
    end

    # No response ever supplied reset_at — a run of header-less transport failures —
    # so the fallback horizon is one full search window of silence. Without it, `used`
    # would sit at the ceiling forever with nothing able to roll it.
    it "rolls a header-less window once a full search window has passed in silence" do
      ledger.bootstrap!(now: frozen_time)
      GithubSearchBudget.where(id: described_class::SINGLETON_ID)
                        .update_all(reset_at: nil, last_request_at: frozen_time - 61,
                                    used: 8, actor_used: 8)

      ledger.reserve!(:actor_search, now: frozen_time)

      expect(budget).to have_attributes(used: 1, actor_used: 1, repository_used: 0)
    end

    it "does not roll a header-less window while the last attempt is still recent" do
      ledger.bootstrap!(now: frozen_time)
      GithubSearchBudget.where(id: described_class::SINGLETON_ID)
                        .update_all(reset_at: nil, last_request_at: frozen_time - 30, used: 8)

      expect { ledger.reserve!(:actor_search, now: frozen_time) }
        .to raise_error(Github::Errors::BudgetExhausted, /search_ceiling_exhausted/)
      expect(budget.used).to eq(8)
    end

    # last_request_at deliberately survives the roll: the pacing contract is "no two
    # searches closer than the interval", and a window boundary between them does not
    # make two requests further apart in time.
    it "keeps pacing continuous across the roll, because the wire does not reset" do
      active_window(used: 8, last_request_at: window_reset - 2)

      expect { ledger.reserve!(:actor_search, now: window_reset + 1) }
        .to raise_error(Github::Errors::BudgetExhausted, /search_pacing/)
      expect(budget.last_request_at).to eq(window_reset - 2)
    end

    # The rollover genuinely happened, so it must survive even when the reservation
    # that discovered it is then refused.
    it "commits the reset even when the reservation is then denied" do
      active_window(used: 8, last_request_at: window_reset - 2)

      suppress(Github::Errors::BudgetExhausted) { ledger.reserve!(:actor_search, now: window_reset + 1) }

      expect(budget.used).to eq(0)
    end
  end

  describe "#reconcile!" do
    it "does nothing when a transport failure produced no snapshot at all" do
      active_window

      expect(ledger.reconcile!(nil, now: frozen_time)).to eq(:no_headers)
    end

    # Folding core's hourly numbers into a per-minute row would import a 3600-second
    # reset as this window's boundary — the mirror of the core ledger refusing a
    # "search" snapshot.
    it "refuses a snapshot from the core resource and leaves the row untouched" do
      active_window(remaining: 9)

      result = ledger.reconcile!(
        snapshot("x-ratelimit-resource" => "core", "x-ratelimit-remaining" => "1"), now: frozen_time
      )

      expect(result).to eq(:resource_mismatch)
      expect(budget).to have_attributes(remaining: 9, reset_at: window_reset)
    end

    # A response with no reservation behind it would mean a request was made without
    # reserving, which is the invariant the whole class exists to hold.
    it "never creates the ledger row, because only a reservation may" do
      expect(ledger.reconcile!(snapshot, now: frozen_time)).to eq(:no_ledger)
      expect(GithubSearchBudget.count).to eq(0)
    end

    it "does nothing with a snapshot that lacks the quantitative trio" do
      active_window(remaining: 9)

      result = ledger.reconcile!(
        Github::RateLimitSnapshot.from_headers({ "x-ratelimit-resource" => "search" },
                                               observed_at: frozen_time),
        now: frozen_time
      )

      expect(result).to eq(:partial_headers)
      expect(budget.remaining).to eq(9)
    end

    # Regression: an earlier draft's transaction block ended on an assignment, so a
    # successful reconcile reported the assigned value rather than :updated and the
    # executor logged every good response as unreconciled.
    it "reports :updated for a good snapshot it applied" do
      active_window

      expect(ledger.reconcile!(snapshot, now: frozen_time)).to eq(:updated)
    end

    it "adopts the observed limit, reset and observation instant" do
      active_window(limit: nil, observed_at: nil)

      ledger.reconcile!(snapshot, now: frozen_time)

      expect(budget).to have_attributes(limit: 10, reset_at: window_reset, observed_at: frozen_time)
    end

    # Within one window remaining only ever moves down — headers may arrive out of
    # order, and the lower number is the one GitHub will actually enforce.
    it "takes the lower of the local estimate and the observed value" do
      active_window(remaining: 3)

      ledger.reconcile!(snapshot("x-ratelimit-remaining" => "9"), now: frozen_time)

      expect(budget.remaining).to eq(3)
    end

    it "adopts an observed value lower than the local estimate" do
      active_window(remaining: 9)

      ledger.reconcile!(snapshot("x-ratelimit-remaining" => "4"), now: frozen_time)

      expect(budget.remaining).to eq(4)
    end

    it "adopts the observed remaining outright when no local estimate exists" do
      active_window(remaining: nil)

      ledger.reconcile!(snapshot("x-ratelimit-remaining" => "7"), now: frozen_time)

      expect(budget.remaining).to eq(7)
    end

    # The read-side block: once the observed remaining is inside the reserve, the next
    # reservation would be denied anyway, so the row says until when.
    it "blocks until the reset once the observed remaining is inside the reserve" do
      active_window

      ledger.reconcile!(snapshot("x-ratelimit-remaining" => "2"), now: frozen_time)

      expect(budget.blocked_until).to eq(window_reset)
    end

    it "sets no block while the observed remaining still clears the reserve" do
      active_window

      ledger.reconcile!(snapshot("x-ratelimit-remaining" => "3"), now: frozen_time)

      expect(budget.blocked_until).to be_nil
    end

    # A superseding reset_at is GitHub saying it counted the in-flight request in the
    # new minute. Zeroing the counters outright would let this window issue one more
    # request than GitHub honours, so the debit rides across into its own lane.
    describe "a window that moves on while a request is in flight" do
      def superseding(remaining: "9")
        snapshot("x-ratelimit-reset" => (window_reset + 60).to_i.to_s,
                 "x-ratelimit-remaining" => remaining)
      end

      it "carries the in-flight debit into the new window as one used" do
        active_window(used: 5, actor_used: 3, repository_used: 2, remaining: nil)

        ledger.reconcile!(superseding, request_class: :actor_search, now: window_reset + 1)

        expect(budget).to have_attributes(used: 1, actor_used: 1, repository_used: 0,
                                          reset_at: window_reset + 60, remaining: 9)
      end

      it "carries a repository request into its own lane" do
        active_window(used: 5, actor_used: 3, repository_used: 2, remaining: nil)

        ledger.reconcile!(superseding, request_class: :repository_search, now: window_reset + 1)

        expect(budget).to have_attributes(used: 1, actor_used: 0, repository_used: 1)
      end
    end
  end

  describe "#block_from!" do
    def limited(status: 403, **headers)
      request = Github::Request.new(url: "https://api.github.com/search/users?q=user%3Aoctocat&per_page=1",
                                    request_class: :actor_search)
      Github::FetchResult.from_response(request: request, status: status,
                                        headers: headers.transform_keys(&:to_s),
                                        body: "", duration_ms: 1.0)
    end

    # 403 with a non-zero remaining classifies as :secondary_limited; with "0" it is
    # :rate_limited — the same discriminator Github::ResponseClassifier applies to core.
    it "prefers Retry-After, the server's explicit instruction" do
      active_window

      ledger.block_from!(limited("retry-after" => "120",
                                 "x-ratelimit-reset" => window_reset.to_i.to_s),
                         now: frozen_time)

      expect(budget.blocked_until).to eq(frozen_time + 120)
    end

    it "falls back to the reset header when no Retry-After was sent" do
      active_window

      ledger.block_from!(limited("x-ratelimit-reset" => window_reset.to_i.to_s), now: frozen_time)

      expect(budget.blocked_until).to eq(window_reset)
    end

    it "falls back to one search window when the response named no instant at all" do
      active_window

      ledger.block_from!(limited, now: frozen_time)

      expect(budget.blocked_until).to eq(frozen_time + described_class::SEARCH_WINDOW_SECONDS)
    end

    it "blocks on a primary exhaustion as well as a secondary limit" do
      active_window

      ledger.block_from!(limited("x-ratelimit-remaining" => "0", "retry-after" => "90"),
                         now: frozen_time)

      expect(budget.blocked_until).to eq(frozen_time + 90)
    end

    # GREATEST ignores NULL, so a block only ever moves later — a short block landing
    # after a long one must not resume searching into an exhausted quota.
    it "only ever moves a block later" do
      active_window

      ledger.block_from!(limited("retry-after" => "300"), now: frozen_time)
      ledger.block_from!(limited("retry-after" => "60"), now: frozen_time)
      expect(budget.blocked_until).to eq(frozen_time + 300)

      ledger.block_from!(limited("retry-after" => "600"), now: frozen_time)
      expect(budget.blocked_until).to eq(frozen_time + 600)
    end

    it "ignores every classification that is not a rate limit" do
      active_window

      ledger.block_from!(limited(status: 500), now: frozen_time)
      ledger.block_from!(limited(status: 200), now: frozen_time)

      expect(budget.blocked_until).to be_nil
    end
  end

  # The row-lock property the single-threaded examples cannot prove: two genuinely
  # separate PostgreSQL sessions reserving at once must serialise on the row, with no
  # lost debit and no deadlock. Transactional tests are off for the reason
  # spec/support/concurrency_helpers.rb documents, paid for with explicit cleanup.
  describe "under concurrency" do
    self.use_transactional_tests = false

    around do |example|
      example.run
    ensure
      ActiveRecord::Base.connection.execute("DELETE FROM github_search_budget")
      restore_connection_pool!
    end

    it "serialises two concurrent reservations into exactly two debits" do
      unpaced = described_class.new(configuration: configuration_with(SEARCH_PACING_SECONDS: "0"))
      now = Time.current

      outcomes = reservation_outcomes(
        in_parallel(2, threads: 2) { unpaced.reserve!(:actor_search, now: now) }
      )

      expect(outcomes[:unexpected]).to be_empty
      expect(outcomes).to include(granted: 2, denied: 0)
      expect(GithubSearchBudget.uncached { GithubSearchBudget.find(described_class::SINGLETON_ID) })
        .to have_attributes(used: 2, actor_used: 2, repository_used: 0)
    end
  end
end
