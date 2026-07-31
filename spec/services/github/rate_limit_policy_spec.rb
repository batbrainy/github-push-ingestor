require "rails_helper"

RSpec.describe Github::RateLimitPolicy do
  let(:now) { frozen_time }
  let(:policy) { described_class.new(backoff: Github::PollBackoff.new(random: instance_double(Random, rand: 0.0))) }

  def fetched(status:, headers: {}, error: nil, classification: nil)
    request = Github::Request.new(url: "https://api.github.com/events?per_page=100", request_class: :poll)
    return Github::FetchResult.from_error(request: request, error: error, classification: classification) if error

    Github::FetchResult.from_response(request: request, status: status, headers: headers,
                                      body: "", duration_ms: 1.0)
  end

  def rate_limited(remaining: "0", reset_at: now + 1800, **headers)
    fetched(status: 403, headers: {
      "x-ratelimit-remaining" => remaining, "x-ratelimit-limit" => "60",
      "x-ratelimit-reset" => reset_at.to_i.to_s, "x-ratelimit-resource" => "core"
    }.merge(headers))
  end

  describe "a primary rate limit (§10: X-RateLimit-Remaining = 0)" do
    before { active_budget_window(now: now) }

    it "blocks every live request until the window GitHub named in the response" do
      decision = policy.apply!(rate_limited, now: now)

      expect(decision).to have_attributes(kind: :primary_rate_limit, blocked_until: now + 1800)
      expect(current_budget.global_blocked_until).to eq(now + 1800)
    end

    it "labels the window blocked, because window rollover is the transition back out" do
      policy.apply!(rate_limited, now: now)

      expect(current_budget).to be_globally_blocked
    end

    # The instant must come from the response that carried the limit, never from the
    # stored reset_at: that column is NULL on a fresh install and after every rollover, so
    # reading it would write NULL, denial_reason would see no block at all, and the poller
    # would spend its whole allowance re-asking a quota that is provably at zero.
    # A row exists — a reservation created it — but no authoritative headers have been
    # applied to it yet. That is the state of a fresh install and of every window
    # immediately after ROLL_WINDOW_SQL, so it is the common case, not a corner.
    context "when the window has never been initialized" do
      before do
        current_budget.update!(window_status: "uninitialized", window_initialized_at: nil,
                               limit: nil, remaining: nil, reset_at: nil)
      end

      it "still blocks, using the response's own reset header" do
        policy.apply!(rate_limited, now: now)

        expect(current_budget.global_blocked_until).to eq(now + 1800)
      end

      it "falls back to a bounded instant when the response carries no reset either" do
        policy.apply!(fetched(status: 403, headers: { "x-ratelimit-remaining" => "0" }), now: now)

        expect(current_budget.global_blocked_until).to eq(now + described_class::MIN_BLOCK_SECONDS)
      end

      # Writing "globally_blocked" over a window that was never initialized used to be a
      # one-way door: BudgetLedger#apply_observation dispatched on the label, so the next
      # good response took a branch that compared a Time to nil and raised, and neither
      # rollover predicate could fire because reset_at was NULL. The label is now written
      # only from active, and the ledger keys on the fact.
      it "leaves the label alone, so the next good response can still initialize the window" do
        policy.apply!(rate_limited(reset_at: now + 1800), now: now)
        expect(current_budget).to be_uninitialized

        snapshot = Github::RateLimitSnapshot.from_headers(
          { "x-ratelimit-limit" => "60", "x-ratelimit-remaining" => "55",
            "x-ratelimit-reset" => (now + 3600).to_i.to_s, "x-ratelimit-resource" => "core" },
          observed_at: now
        )

        expect { Github::BudgetLedger.new.reconcile!(snapshot, request_class: :poll, now: now) }
          .not_to raise_error
        expect(current_budget).to be_active
      end
    end
  end

  # §10: "Secondary rate limits are global. They are IP-scoped, and they can arise on any
  # live request — including enrichment, which has no source row."
  describe "a secondary rate limit" do
    before { active_budget_window(now: now) }

    it "honours Retry-After and hands the same instant back for the source's own state" do
      decision = policy.apply!(rate_limited(remaining: "42", "retry-after" => "300"), now: now)

      expect(decision).to have_attributes(kind: :secondary_rate_limit, blocked_until: now + 300,
                                          source_retry_at: now + 300)
      expect(current_budget.global_blocked_until).to eq(now + 300)
    end

    it "floors a Retry-After shorter than §10's stated minute" do
      policy.apply!(rate_limited(remaining: "42", "retry-after" => "5"), now: now)

      expect(current_budget.global_blocked_until).to eq(now + described_class::MIN_BLOCK_SECONDS)
    end

    # An absurd Retry-After would otherwise halt the whole application — including
    # enrichment, which has no source row to recover from it — so it is capped and the
    # adjustment is logged rather than silently obeyed.
    it "caps a Retry-After longer than one rate-limit window" do
      policy.apply!(rate_limited(remaining: "42", "retry-after" => "86400"), now: now)

      expect(current_budget.global_blocked_until).to eq(now + described_class::MAX_BLOCK_SECONDS)
    end

    # Absent, zero, negative and unparseable all mean the same thing: no usable
    # instruction. `now + nil` raises and `now + nil.to_i` is no block at all, which is the
    # response most likely to escalate GitHub's throttling.
    #
    # The streak is reset between iterations so each case is measured against the same
    # first-failure delay; the escalation across a genuine run is asserted separately below.
    it "backs off on its own terms when Retry-After is absent, zero, negative, or unparseable" do
      [ nil, "0", "-5", "immediately" ].each do |value|
        current_budget.update!(global_blocked_until: nil, consecutive_secondary_limits: 0)
        headers = value.nil? ? {} : { "retry-after" => value }

        expect { policy.apply!(rate_limited(remaining: "42", **headers), now: now) }.not_to raise_error
        expect(current_budget.global_blocked_until).to eq(now + described_class::MIN_BLOCK_SECONDS)
      end
    end

    # RFC 9110 permits both Retry-After forms and §10 lists the header among the ones to
    # process without qualifying which. Leaving the date form unread would collapse a
    # server-supplied "wait 45 minutes" into the 60-second fallback — obeying an
    # instruction far shorter than the one given.
    it "honours an HTTP-date Retry-After, resolved against the observation instant" do
      policy.apply!(rate_limited(remaining: "42", "retry-after" => (now + 900).httpdate), now: now)

      expect(current_budget.global_blocked_until).to eq(now + 900)
    end

    # A date already in the past carries no usable instruction, so it falls through to the
    # same backoff as an absent header rather than producing a block in the past.
    it "falls back when the HTTP-date has already passed" do
      policy.apply!(rate_limited(remaining: "42", "retry-after" => (now - 300).httpdate), now: now)

      expect(current_budget.global_blocked_until).to eq(now + described_class::MIN_BLOCK_SECONDS)
    end

    # A secondary limit expires on a Retry-After unrelated to the window boundary, and
    # nothing would put the label back — unlike the two reset-backed blocks, which
    # ROLL_WINDOW_SQL restores when the window rolls.
    it "leaves the window label alone, because nothing would restore it" do
      policy.apply!(rate_limited(remaining: "42", "retry-after" => "300"), now: now)

      expect(current_budget).to be_active
    end

    # §10: "set global_blocked_until from Retry-After (or >= 1 minute with exponential
    # backoff when the header is absent)". Without the streak the second half of that
    # sentence does not exist: a hardcoded first attempt makes every block in a run the
    # same ~60 seconds, so an IP GitHub is actively throttling is re-probed at a constant
    # rate for as long as the throttling lasts.
    describe "a run of secondary limits with no Retry-After" do
      def block_delays(count)
        (1..count).map do
          current_budget.update!(global_blocked_until: nil)
          policy.apply!(rate_limited(remaining: "42"), now: now)
          (current_budget.global_blocked_until - now).to_i
        end
      end

      it "escalates exponentially from the minimum block" do
        expect(block_delays(4)).to eq([ 60, 120, 240, 480 ])
      end

      it "counts each limit once, on the row every process reads" do
        block_delays(3)

        expect(current_budget.consecutive_secondary_limits).to eq(3)
      end

      # Waiting longer than a window buys nothing — the quota has refreshed by then — and
      # an unbounded ladder would defer a recovered IP into next week.
      it "caps at one rate-limit window" do
        current_budget.update!(consecutive_secondary_limits: 20)

        expect(block_delays(1)).to eq([ described_class::MAX_BLOCK_SECONDS ])
      end

      # The escalation is in *consecutive* limits, so one live request that GitHub answers
      # without throttling ends the run and the next block starts from the floor again.
      it "starts over after a request completes without a secondary limit" do
        block_delays(3)

        policy.apply!(fetched(status: 200, headers: { "x-ratelimit-resource" => "core" }), now: now)

        expect(current_budget.consecutive_secondary_limits).to eq(0)
        expect(block_delays(1)).to eq([ 60 ])
      end

      # A 304 is a completed conditional request that GitHub answered and charged for,
      # which is the same evidence a 200 carries: this IP is not being throttled.
      it "treats a 304 as evidence the throttling ended" do
        block_delays(2)

        policy.apply!(fetched(status: 304, headers: { "x-ratelimit-resource" => "core" }), now: now)

        expect(current_budget.consecutive_secondary_limits).to eq(0)
      end

      # A timeout or a 5xx is GitHub failing to answer, not GitHub declining to throttle.
      # Neither escalating nor clearing on it is what keeps the count a record of verdicts.
      it "leaves the streak alone when the request never got a verdict" do
        block_delays(2)

        policy.apply!(fetched(status: nil, error: Github::Errors::RequestTimeout.new("boom"),
                              classification: :timeout), now: now)

        expect(current_budget.consecutive_secondary_limits).to eq(2)
      end

      # The two conditions are unrelated: a primary exhaustion is relieved by the window
      # rolling, and deferring it on an unrelated secondary run would strand the poller
      # past its own reset.
      it "does not escalate a primary-limit fallback on the secondary streak" do
        current_budget.update!(consecutive_secondary_limits: 5, global_blocked_until: nil)

        # remaining "0" with no parseable reset is the primary branch's fallback path.
        policy.apply!(fetched(status: 403, headers: {
                                "x-ratelimit-remaining" => "0", "x-ratelimit-limit" => "60",
                                "x-ratelimit-resource" => "core"
                              }), now: now)

        expect(current_budget.global_blocked_until).to eq(now + described_class::MIN_BLOCK_SECONDS)
      end
    end

    # Every other example here injects rand: 0.0, which makes the assertions exact and
    # would equally pass if jitter had been dropped from the production path. These two
    # pin that a real Random reaches global_blocked_until, without making the suite
    # depend on a draw.
    describe "jitter on the fallback block" do
      let(:band) { (now + described_class::MIN_BLOCK_SECONDS)..(now + (described_class::MIN_BLOCK_SECONDS * 1.25)) }

      it "reaches the persisted block through a seeded Random" do
        seeded = described_class.new(backoff: Github::PollBackoff.new(random: Random.new(20_260_731)))

        seeded.apply!(rate_limited(remaining: "42"), now: now)

        expect(current_budget.global_blocked_until).to be_between(band.first, band.last).exclusive
      end

      it "reaches it through the production default too" do
        described_class.new.apply!(rate_limited(remaining: "42"), now: now)

        expect(current_budget.global_blocked_until).to be_between(band.first, band.last)
      end
    end
  end

  describe "a budget denial" do
    before { active_budget_window(now: now) }

    def denied(reason, request_class: :poll)
      fetched(status: nil, error: Github::Errors::BudgetExhausted.new(request_class, reason),
              classification: :budget_denied)
    end

    # §10 lists "usable budget has reached the global reserve" among the conditions that
    # stop every live request.
    it "blocks globally when the shared reserve has been reached" do
      decision = policy.apply!(denied(:reserve_reached), now: now)

      expect(decision.kind).to eq(:reserve_reached)
      expect(current_budget.global_blocked_until).to eq(current_budget.reset_at)
    end

    # The bug Appendix D item 2 exists to prevent: one timestamp cannot serve both, so
    # polling spending its twelve attempts must never stop enrichment. Class blocking is
    # derived from counters and never written here.
    it "writes no global block when only this class is exhausted" do
      decision = policy.apply!(denied(:class_allowance_exhausted), now: now)

      expect(decision.kind).to eq(:none)
      expect(current_budget.global_blocked_until).to be_nil
    end

    it "writes nothing for a block that is already in force" do
      expect(policy.apply!(denied(:globally_blocked), now: now).kind).to eq(:none)
    end

    # §10: "Actor/repository share exhaustion lives inside BudgetLedger.reserve!(:actor |
    # :repository) and never touches the global block." A fairness refusal between the two
    # enrichment classes is the furthest thing from a condition that should stop polling.
    it "writes no global block when only one enrichment class has spent its share" do
      decision = policy.apply!(denied(:share_exhausted, request_class: :actor), now: now)

      expect(decision.kind).to eq(:none)
      expect(current_budget.global_blocked_until).to be_nil
    end
  end

  describe "everything else" do
    before { active_budget_window(now: now) }

    it "leaves the ledger alone for a healthy response, a server error, and a held gate" do
      [ fetched(status: 200, headers: { "x-ratelimit-remaining" => "55" }),
        fetched(status: 500),
        fetched(status: nil, error: Github::Errors::GateUnavailable.new, classification: :gate_unavailable) ].each do |result|
        expect(policy.apply!(result, now: now).kind).to eq(:none)
      end

      expect(current_budget.global_blocked_until).to be_nil
    end

    # A routine X-RateLimit-Reset on a successful response must never defer anything —
    # §9's "reset_at is informational" and the reason the components are separate at all.
    it "does not block on a 200 that merely reports when the window resets" do
      policy.apply!(fetched(status: 200, headers: {
        "x-ratelimit-remaining" => "55", "x-ratelimit-reset" => (now + 3600).to_i.to_s
      }), now: now)

      expect(current_budget.global_blocked_until).to be_nil
    end
  end

  describe "an existing block" do
    before { active_budget_window(now: now) }

    # The global gate orders requests, not the post-response writes that follow them, so a
    # short secondary block landing after a long primary one is reachable. Letting it win
    # would resume polling into an exhausted quota for the rest of the window.
    it "is never shortened by a later, shorter one" do
      policy.apply!(rate_limited(reset_at: now + 3600), now: now)
      policy.apply!(rate_limited(remaining: "42", "retry-after" => "60"), now: now)

      expect(current_budget.global_blocked_until).to eq(now + 3600)
    end

    it "is extended by a later, longer one" do
      policy.apply!(rate_limited(remaining: "42", "retry-after" => "60"), now: now)
      policy.apply!(rate_limited(reset_at: now + 3600), now: now)

      expect(current_budget.global_blocked_until).to eq(now + 3600)
    end
  end

  describe "with no ledger row" do
    it "creates none, because a response without a reservation would mean a request was made without one" do
      expect { policy.apply!(rate_limited, now: now) }.not_to change(GithubApiBudget, :count).from(0)
    end
  end
end
