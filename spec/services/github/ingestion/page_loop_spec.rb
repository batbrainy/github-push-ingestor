require "rails_helper"

# §12's D5 ("pagination stopping conditions — cap / allowance / no-next-link / empty page")
# and D6 ("ETag scoping and 304 behavior including quota accounting"), against the real
# executor — gate, ledger, URL policy — over the offline corpus.
RSpec.describe Github::Ingestion::PageLoop do
  let(:event_source) { fixture_event_source }
  let(:source) { Github::EventSources::Base.for(event_source) }
  let(:run_id) { SecureRandom.uuid }

  before { active_budget_window(now: frozen_time) }

  def page_loop(transport:, max_pages: 1)
    configuration = configuration_with("MAX_PAGES_PER_POLL" => max_pages.to_s, "GITHUB_MODE" => "fixture")

    described_class.new(
      executor: fixture_executor(transport: transport, ledger: ledger_for(configuration)),
      writer: Github::Ingestion::PageWriter.new(clock: -> { frozen_time }),
      configuration: configuration,
      rate_limit_policy: Github::RateLimitPolicy.new(ledger: ledger_for(configuration)),
      clock: -> { frozen_time }
    )
  end

  def walk(scenario: "default", max_pages: 1, transport: fixture_transport(scenario: scenario), etag: nil)
    [ page_loop(transport: transport, max_pages: max_pages).run(source, run_id: run_id, etag: etag), transport ]
  end

  def conditional_headers(transport)
    transport.requests.map { |request| request[:headers]["if-none-match"] }
  end

  # ---------------------------------------------------------------- D5: stopping

  describe "the four stopping conditions (§9)" do
    # The page cap is checked after processing page N and before building request N+1, so
    # a capped page is never requested at all. An off-by-one here costs a real request out
    # of twelve an hour.
    it "stops at the configured page cap, having requested exactly that many pages" do
      outcome, transport = walk(scenario: "paginated", max_pages: 2)

      expect(outcome).to be_completed
      expect(outcome.stop_reason).to eq(:page_cap)
      expect(outcome.tally.pages_fetched).to eq(2)
      expect(transport.requests.size).to eq(2)
      expect(current_budget.poll_used).to eq(2)
    end

    it "stops when the budget denies the next reservation, keeping the pages already written" do
      active_budget_window(now: frozen_time, poll_used: 11, poll_allowance: 12)

      outcome, transport = walk(scenario: "paginated", max_pages: 3)

      # Not `failed`: pages one to N-1 are durable, so "the attempt happened and did not
      # produce usable events" would be false. Not `deferred`: that means nothing was
      # fetched, and would drop a run holding real events out of
      # IngestionRun::SUCCESSFUL_STATUSES and therefore out of "Latest successful run".
      expect(outcome).to be_completed
      expect(outcome.stop_reason).to eq(:budget_denied)
      expect(outcome.tally.pages_fetched).to eq(1)
      expect(outcome.tally.events_created).to eq(4)
      expect(transport.requests.size).to eq(1)
      expect(current_budget.poll_used).to eq(12)
    end

    it "stops when GitHub offers no next Link" do
      outcome, = walk(scenario: "paginated_final_page", max_pages: 3)

      expect(outcome.stop_reason).to eq(:no_next_link)
      expect(outcome.tally.pages_fetched).to eq(2)
    end

    it "stops on an empty page, and still counts it as fetched" do
      outcome, = walk(scenario: "paginated", max_pages: 3)

      expect(outcome.stop_reason).to eq(:empty_page)
      expect(outcome.tally.to_h).to include(pages_fetched: 3, events_received: 11)
    end
  end

  describe "a full walk of the corpus" do
    let(:result) { walk(scenario: "paginated", max_pages: 3).first }

    it "processes every page and accumulates one tally across all three" do
      expect(result.tally.to_h).to include(
        pages_fetched: 3, events_received: 11, push_events_seen: 9, events_created: 6,
        duplicates_skipped: 1, events_quarantined: 3, events_ignored: 1, events_failed: 0
      )
    end

    # §9: "No stop-on-known-event for the live source. Documented event latency is 30s–6h
    # and the API does not guarantee that one previously seen event implies all older
    # positions are already stored." The corpus makes the absence provable rather than
    # merely documented: page two repeats page one's first event, so a known-event stop
    # would have ended the walk there.
    it "does not stop when a page repeats an event it has already seen" do
      expect(result.tally.pages_fetched).to eq(3)
      expect(result.tally.duplicates_skipped).to eq(1)
      expect(PushEvent.where(github_event_id: "58000000001").count).to eq(1)
    end

    it "debits one poll attempt per page" do
      expect { result }.to change { current_budget.reload.poll_used }.from(0).to(3)
    end
  end

  # --------------------------------------------------------------- D6: ETag and 304

  describe "ETag scoping (§9: the persisted ETag applies only to the canonical first-page request)" do
    it "sends the stored ETag on page one and on no other page" do
      _, transport = walk(scenario: "paginated", max_pages: 3, etag: 'W/"stored"')

      expect(conditional_headers(transport)).to eq([ 'W/"stored"', nil, nil ])
    end

    it "sends no conditional header at all when there is no stored ETag" do
      _, transport = walk(scenario: "paginated", max_pages: 3)

      expect(conditional_headers(transport)).to all(be_nil)
    end

    it "returns page one's ETag for the caller to persist" do
      outcome, = walk

      expect(outcome.etag).to eq('W/"3f2a1c9d0b7e4a58c1d2e3f4a5b6c7d8"')
    end
  end

  describe "a 304 Not Modified" do
    # The default scenario's second scripted response is a 304 carrying the same ETag, so
    # one transport reaching for page one twice models a long-lived process.
    let(:transport) { fixture_transport }
    let!(:first) { walk(transport: transport).first }
    let!(:second) { page_loop(transport: transport).run(source, run_id: run_id, etag: first.etag) }

    it "processes nothing and records the run as not modified" do
      expect(second).to be_not_modified
      expect(second.tally.to_h.values).to all(eq(0))
      expect(PushEvent.count).to eq(4)
    end

    # §10 and Appendix A item 1: the reservation stays debited, because a dated
    # unauthenticated probe showed x-ratelimit-used incrementing across a 304. Two
    # attempts, two debits. BudgetLedger has no credit path by construction, so this needs
    # no code — only proof that none was added.
    it "still spends the poll attempt" do
      expect(current_budget.poll_used).to eq(2)
    end

    it "was answered conditionally, using the ETag the first walk stored" do
      expect(conditional_headers(transport)).to eq([ nil, 'W/"3f2a1c9d0b7e4a58c1d2e3f4a5b6c7d8"' ])
    end

    # RFC 9110: a 304 may carry an ETag, and by definition it is the current validator.
    # Never clearing it is the load-bearing half — clearing would make every later poll
    # unconditional for no reason.
    it "keeps the validator the 304 echoed" do
      expect(second.etag).to eq(first.etag)
    end
  end

  # --------------------------------------------------------------- failure modes

  describe "a page after the first that GitHub will not serve" do
    it "keeps the pages already written and records a page-scoped error" do
      transport = fixture_transport(scenario: "paginated")
      # Page two is denied by the ledger rather than by GitHub, which is the same shape:
      # the walk stops, page one stands.
      active_budget_window(now: frozen_time, poll_used: 11, poll_allowance: 12)

      outcome = page_loop(transport: transport, max_pages: 3).run(source, run_id: run_id)

      expect(outcome).to be_completed
      expect(outcome.last_error).to start_with("page 2:")
      expect(PushEvent.count).to eq(4)
    end
  end

  describe "a Link header pointing somewhere it should not" do
    # §10's SSRF boundary. Base#linked_page_request marks the target payload-supplied, so
    # UrlPolicy.validate_payload_url! re-parses it under the full *live* policy whatever
    # the mode — and RequestExecutor validates before the gate, so a refused URL never
    # reaches a reservation.
    it "spends nothing on an off-host target and keeps the page it already has" do
      transport = scripted(link: '<https://evil.example.com/events?page=2>; rel="next"')

      outcome = page_loop(transport: transport, max_pages: 3).run(source, run_id: run_id)

      expect(outcome).to be_completed
      expect(outcome.stop_reason).to eq(:page_error)
      expect(outcome.tally.pages_fetched).to eq(1)
      expect(current_budget.poll_used).to eq(1)
    end

    # Bounded only by MAX_PAGES_PER_POLL otherwise — at a cap of twelve, one run would
    # spend the entire hourly poll allowance walking the same page.
    it "stops rather than following a Link back to the page it just fetched" do
      transport = scripted(link: '<https://api.github.com/events?per_page=100>; rel="next"')

      outcome = page_loop(transport: transport, max_pages: 12).run(source, run_id: run_id)

      expect(outcome.stop_reason).to eq(:link_loop)
      expect(outcome.tally.pages_fetched).to eq(1)
      expect(current_budget.poll_used).to eq(1)
    end

    it "treats a Link header it cannot read as no next page" do
      transport = scripted(link: "not a link header")

      expect(page_loop(transport: transport, max_pages: 3).run(source, run_id: run_id).stop_reason)
        .to eq(:no_next_link)
    end
  end

  # A transport that answers every request with page one plus the given Link header, so a
  # degenerate header can be exercised without authoring a corpus scenario for a response
  # GitHub would never actually send. It records what it was asked for, the same way
  # Github::Transports::Fixture does, so conditional-header assertions work against it too.
  class ScriptedLinkTransport
    MODE = :fixture

    def initialize(link:, body:, reset_at:)
      @link = link
      @body = body
      @reset_at = reset_at
      @requests = []
    end

    attr_reader :requests

    def get(validated_url, headers: {})
      @requests << { url: validated_url.to_s, headers: headers.transform_keys(&:downcase) }

      Github::Transports::Response.new(
        status: 200, body: @body, url: validated_url, duration_ms: 1.0,
        headers: { "etag" => 'W/"scripted"', "link" => @link, "x-ratelimit-resource" => "core",
                   "x-ratelimit-limit" => "60", "x-ratelimit-remaining" => "59",
                   "x-ratelimit-reset" => @reset_at.to_i.to_s }
      )
    end
  end

  def scripted(link:)
    ScriptedLinkTransport.new(
      link: link,
      body: Rails.root.join("fixtures", "github", "bodies", "events", "page-1.json").read,
      reset_at: frozen_time + 3600
    )
  end
end
