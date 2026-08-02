require "rails_helper"

# A backlog larger than one Search window's spendable budget, driven through the same
# claims, request gate, both ledgers, response classification, document parsers and
# entity-state writes as production. WebMock prevents external connections while the
# Faraday request stack is still exercised.
#
# The ceiling is lowered to 4 with the default reserve of 2, so each minute window
# grants exactly two Search requests — small enough that draining fifty entities forces
# three window rolls, which is the durability property Appendix F states: quota
# exhaustion defers the FIFO, it never shortens it.
RSpec.describe "a durable staged backlog spanning quota windows", type: :integration do
  let(:now) { frozen_time }
  let(:actor_ids) { (10_001..10_025).to_a }
  let(:repository_ids) { (20_001..20_025).to_a }

  # The five repositories the Search echo pretends not to know — one per position
  # flavour (early, mid, late in their batches) — which is exactly the shape that
  # admits them to the bounded core detail-fallback lane.
  let(:missing_repository_ids) { [ 20_003, 20_007, 20_012, 20_018, 20_024 ].freeze }

  let(:configuration) do
    configuration_with(
      "SEARCH_REQUEST_CEILING" => "4", "SEARCH_SAFETY_RESERVE" => "2",
      "SEARCH_BATCH_SIZE" => "10", "SEARCH_PACING_SECONDS" => "0",
      "CORE_DETAIL_FALLBACK_ALLOWANCE" => "4"
    )
  end

  it "drains the FIFO across search windows and finishes the fallbacks next core window" do
    search_requests = []
    current_time = now
    clock = -> { current_time }

    stub_search_echo!(search_requests, -> { current_time })
    stub_detail_documents!(-> { current_time })
    create_backlog!

    executor = live_stubbed_executor(clock: clock)
    batch_runner = live_stubbed_batch_runner(executor: executor, clock: clock)
    detail_runner = live_stubbed_detail_runner(executor: executor, clock: clock)
    admission = Github::Enrichment::Admission.new(configuration: configuration)
    open_window!(executor: executor, at: current_time)

    # ---- Act 1: the Search lane, two requests per minute window -------------------

    # Window 1: the ceiling-minus-reserve pair of requests drains the oldest twenty
    # actors, ten at a time, in strict created_at,id order.
    2.times do
      expect(batch_runner.call(entity_class: GithubActor))
        .to have_attributes(status: "completed", requested_count: 10, valid_count: 10)
    end

    # The third reservation is refused by the ledger under its row lock, the batch row
    # records the reason, and the five leased rows come back bit-identical.
    remaining_actors = GithubActor.where(github_id: actor_ids.last(5)).order(:id)
    before_rows = remaining_actors.map(&:attributes)

    expect(admission.search(now: current_time).reason).to eq(:search_ceiling_exhausted)
    expect(batch_runner.call(entity_class: GithubActor))
      .to have_attributes(status: "deferred", deferral_reason: "budget_denied")

    expect(remaining_actors.reload.map(&:attributes)).to eq(before_rows)
    expect(EnrichmentBatch.order(:id).last)
      .to have_attributes(status: "deferred")
    expect(EnrichmentBatch.order(:id).last.last_error).to include("search_ceiling_exhausted")
    expect(current_search_budget).to have_attributes(used: 2, actor_used: 2, repository_used: 0)

    # Window 2: sixty-one seconds later the ledger rolls the window on its next
    # reservation — no sweeper, no reset job — and draining resumes where it stopped.
    current_time = now + 61

    expect(batch_runner.call(entity_class: GithubActor))
      .to have_attributes(status: "completed", requested_count: 5, valid_count: 5)
    expect(batch_runner.call(entity_class: GithubRepository))
      .to have_attributes(status: "completed", requested_count: 10, valid_count: 8,
                          fallback_count: 2)

    # Window 3: the remaining repositories, again FIFO, again two requests.
    current_time = now + 122

    expect(batch_runner.call(entity_class: GithubRepository))
      .to have_attributes(status: "completed", requested_count: 10, valid_count: 8,
                          fallback_count: 2)
    expect(batch_runner.call(entity_class: GithubRepository))
      .to have_attributes(status: "completed", requested_count: 5, valid_count: 4,
                          fallback_count: 1)

    # The exact identifiers of every Search request, across every window, in FIFO
    # order — the whole point of the durable backlog.
    expect(search_requests).to eq([
      [ :actor, actor_logins.first(10) ],
      [ :actor, actor_logins[10, 10] ],
      [ :actor, actor_logins.last(5) ],
      [ :repository, repository_names.first(10) ],
      [ :repository, repository_names[10, 10] ],
      [ :repository, repository_names.last(5) ]
    ])

    expect(current_search_budget).to have_attributes(
      used: 2, actor_used: 0, repository_used: 2, remaining: 8, blocked_until: nil
    )

    # ---- Act 2: the bounded core detail-fallback lane -----------------------------

    fallback = GithubRepository.where(github_id: missing_repository_ids)
    expect(fallback.pluck(:enrichment_stage).uniq).to eq([ "detail_pending" ])
    expect(fallback.order(:detail_pending_at, :id).pluck(:github_id))
      .to eq(missing_repository_ids)

    # Four fallbacks fit the CORE_DETAIL_FALLBACK_ALLOWANCE. The actor lane has no
    # eligible candidate, so the third and fourth ride borrowed slots past the
    # repository share guarantee — exactly the CycleRunner's borrow decision.
    [ false, false, true, true ].each do |borrowed|
      expect(detail_runner.call(entity_class: GithubRepository, borrow: borrowed))
        .to have_attributes(status: "completed")
    end

    expect(admission.detail(now: current_time).reason).to eq(:class_exhausted)
    expect(detail_runner.call(entity_class: GithubRepository, borrow: true))
      .to have_attributes(status: "deferred", reason: "budget_denied")
    expect(EnrichmentBatch.order(:id).last.last_error).to include("class_allowance_exhausted")
    expect(current_budget).to have_attributes(poll_used: 1, enrichment_used: 4)

    # The fifth waits out the core window as durable detail_pending work, and the next
    # window — opened by the same bootstrap poll production uses — finishes it.
    current_time = now + 7200
    open_window!(executor: executor, at: current_time)

    expect(detail_runner.call(entity_class: GithubRepository))
      .to have_attributes(status: "completed", github_id: missing_repository_ids.last)

    # Every one of the fifty rows completed the contract; quota pressure produced
    # deferrals and window waits, never a terminal outcome.
    expect(GithubActor.where(github_id: actor_ids).distinct.pluck(:enrichment_status, :enrichment_stage))
      .to eq([ [ "complete", "contract_complete" ] ])
    expect(GithubRepository.where(github_id: repository_ids)
                           .distinct.pluck(:enrichment_status, :enrichment_stage))
      .to eq([ [ "complete", "contract_complete" ] ])
    expect(GithubRepository.where(enrichment_stage: "terminal").count).to eq(0)

    expect(current_budget).to have_attributes(
      poll_used: 1, enrichment_used: 1, actor_share_used: 0, repository_share_used: 1
    )
    expect(current_search_budget).to have_attributes(used: 2, actor_used: 0, repository_used: 2)
    expect(WebMock).to have_requested(:get, "https://api.github.com/events?per_page=1").twice
  end

  private

  def actor_logins
    actor_ids.map { |github_id| "backlog-user-#{github_id}" }
  end

  def repository_names
    repository_ids.map { |github_id| "backlog/repo-#{github_id}" }
  end

  # created_at staggers the FIFO; updated_at is pinned to the frozen clock so the
  # deferred claim's release is provably a bit-identical restore.
  def create_backlog!
    actor_ids.each_with_index do |github_id, index|
      create_actor(
        github_id: github_id, login: "backlog-user-#{github_id}",
        display_login: "backlog-user-#{github_id}",
        api_url: "https://api.github.com/users/backlog-user-#{github_id}",
        created_at: now - 1000 + index, updated_at: now
      )
    end

    repository_ids.each_with_index do |github_id, index|
      create_repository(
        github_id: github_id, full_name: "backlog/repo-#{github_id}", name: "repo-#{github_id}",
        api_url: "https://api.github.com/repos/backlog/repo-#{github_id}",
        created_at: now - 1000 + index, updated_at: now
      )
    end
  end

  # Echoes every requested qualifier back as a validating Search item — except the five
  # missing repositories — with authoritative per-minute Search headers computed from
  # the ledger's own post-debit counter.
  def stub_search_echo!(search_requests, current_time)
    stub_request(:get, %r{\Ahttps://api\.github\.com/search/(users|repositories)\?})
      .to_return do |request|
        query = URI.decode_www_form(request.uri.query.to_s).to_h
        identifiers = query.fetch("q").split(" ").map { |qualifier| qualifier.split(":", 2).last }
        actor = request.uri.path.end_with?("/users")
        search_requests << [ actor ? :actor : :repository, identifiers ]

        items = identifiers.filter_map do |identifier|
          github_id = identifier[/(\d+)\z/, 1].to_i
          next if !actor && missing_repository_ids.include?(github_id)

          actor ? actor_item(github_id, identifier) : repository_item(github_id, identifier)
        end

        {
          status: 200,
          headers: search_headers(current_time.call),
          body: JSON.generate(
            "total_count" => items.length, "incomplete_results" => false, "items" => items
          )
        }
      end
  end

  def search_headers(at)
    {
      "Content-Type" => "application/json",
      "X-RateLimit-Resource" => "search",
      "X-RateLimit-Limit" => "10",
      "X-RateLimit-Remaining" => (10 - current_search_budget.used).to_s,
      "X-RateLimit-Used" => current_search_budget.used.to_s,
      "X-RateLimit-Reset" => (at + 60).to_i.to_s
    }
  end

  def actor_item(github_id, login)
    { "id" => github_id, "login" => login, "type" => "User" }
  end

  def repository_item(github_id, full_name)
    {
      "id" => github_id, "full_name" => full_name,
      "owner" => { "id" => github_id + 100_000, "login" => "backlog" },
      "fork" => false, "archived" => false, "default_branch" => "main",
      "description" => "Backlog repository #{github_id}", "language" => "Ruby",
      "created_at" => "2026-07-01T00:00:00Z"
    }
  end

  # The detail lane fetches the stored payload api_url through the CORE ledger; the
  # body must satisfy the full repository contract, and the headers carry the same
  # hourly core window the bootstrap poll opened.
  def stub_detail_documents!(current_time)
    stub_request(:get, %r{\Ahttps://api\.github\.com/repos/backlog/repo-\d+\z})
      .to_return do |request|
        github_id = request.uri.path[/-(\d+)\z/, 1].to_i

        {
          status: 200,
          headers: {
            "Content-Type" => "application/json",
            "X-RateLimit-Resource" => "core", "X-RateLimit-Limit" => "60",
            "X-RateLimit-Remaining" => "50",
            "X-RateLimit-Reset" => (current_budget.reset_at || current_time.call + 3600).to_i.to_s
          },
          body: JSON.generate(repository_item(github_id, "backlog/repo-#{github_id}"))
        }
      end
  end

  def live_stubbed_executor(clock:)
    Github::RequestExecutor.new(
      transport: Github::Transports::Faraday.new,
      ledger: ledger_for(configuration),
      search_ledger: search_ledger_for(configuration),
      mode: :live, sleeper: ->(_seconds) { }, clock: clock
    )
  end

  def live_stubbed_batch_runner(executor:, clock:)
    Github::Enrichment::BatchRunner.new(
      executor: executor, configuration: configuration,
      claim: Github::Enrichment::BatchClaim.new(configuration: configuration),
      search_ledger: search_ledger_for(configuration),
      backoff: jitterless_backoff(configuration: configuration),
      clock: clock
    )
  end

  def live_stubbed_detail_runner(executor:, clock:)
    Github::Enrichment::DetailRunner.new(
      executor: executor, configuration: configuration,
      claim: Github::Enrichment::DetailClaim.new(configuration: configuration),
      backoff: jitterless_backoff(configuration: configuration),
      clock: clock
    )
  end

  # The core window opens the way production opens it: one bootstrap poll whose
  # authoritative headers initialize the hourly window (§7). Re-registered per call so
  # the reset instant tracks the travelling clock.
  def open_window!(executor:, at:)
    stub_request(:get, "https://api.github.com/events?per_page=1").to_return(
      status: 200, body: "[]",
      headers: {
        "Content-Type" => "application/json",
        "X-RateLimit-Resource" => "core", "X-RateLimit-Limit" => "60",
        "X-RateLimit-Remaining" => "59", "X-RateLimit-Used" => "1",
        "X-RateLimit-Reset" => (at + 3600).to_i.to_s
      }
    )

    result = executor.call(
      Github::Request.new(url: "https://api.github.com/events?per_page=1", request_class: :poll)
    )
    expect(result.classification).to eq(:ok)
    expect(current_budget).to have_attributes(
      window_status: "active", poll_used: 1, enrichment_used: 0,
      actor_share_used: 0, repository_share_used: 0, enrichment_allowance: 4
    )
  end
end
