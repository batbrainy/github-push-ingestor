require "rails_helper"

# A backlog larger than one default enrichment allowance, driven through the same runner,
# request gate, ledger, response classification, document parser and entity state writes as
# production. WebMock prevents external connections while the Faraday request stack is still
# exercised.
RSpec.describe "a durable enrichment backlog spanning quota windows", type: :integration do
  let(:now) { frozen_time }
  let(:actor_ids) { (10_001..10_023).to_a }
  let(:repository_ids) { (20_001..20_023).to_a }
  let(:configuration) do
    configuration_with(
      POLL_INTERVAL_SECONDS: "300", MAX_PAGES_PER_POLL: "1",
      ENABLED_LIVE_SOURCE_COUNT: "1", RATE_LIMIT_RESERVE: "8",
      ACTOR_ENRICHMENT_SHARE: "0.50"
    )
  end

  it "drains forty FIFO candidates, preserves every remainder, and finishes next window" do
    request_order = []
    stub_backlog_documents!(request_order)
    create_backlog!

    current_time = now
    clock = -> { current_time }
    executor = live_stubbed_executor(clock: clock, configuration: configuration)
    runner = live_stubbed_runner(executor: executor, clock: clock, configuration: configuration)
    open_window!(executor: executor, at: current_time)

    first_window = Array.new(40) { runner.call }

    expect(first_window).to all(be_enriched)
    expect(request_order).to eq(
      actor_ids.first(20).map { [ :actor, _1 ] } +
      repository_ids.first(20).map { [ :repository, _1 ] }
    )
    expect(current_budget).to have_attributes(
      poll_used: 1, enrichment_used: 40, actor_share_used: 20, repository_share_used: 20
    )

    expect(runner.call).to have_attributes(status: "deferred", deferral_reason: "class_exhausted")
    expect(request_order.length).to eq(40)
    expect_remaining_backlog(actor_ids.last(3), repository_ids.last(3))

    current_time = now + 7200
    open_window!(executor: executor, at: current_time)

    second_window = Array.new(6) { runner.call }

    expect(second_window).to all(be_enriched)
    expect(request_order.last(6)).to eq(
      actor_ids.last(3).map { [ :actor, _1 ] } +
      repository_ids.last(3).map { [ :repository, _1 ] }
    )
    expect(current_budget).to have_attributes(
      poll_used: 1, enrichment_used: 6, actor_share_used: 3, repository_share_used: 3
    )
    expect(GithubActor.where(github_id: actor_ids).distinct.pluck(:enrichment_status))
      .to eq([ "complete" ])
    expect(GithubRepository.where(github_id: repository_ids).distinct.pluck(:enrichment_status))
      .to eq([ "complete" ])
    expect(runner.call).to have_attributes(status: "idle", deferral_reason: "no_candidate")
    expect(request_order.length).to eq(46)
    expect(WebMock).to have_requested(:get, "https://api.github.com/events?per_page=1").twice
  end

  private

  def create_backlog!
    actor_ids.each_with_index do |github_id, index|
      create_actor(
        github_id: github_id, login: "backlog-user-#{github_id}",
        display_login: "backlog-user-#{github_id}",
        api_url: "https://api.github.com/users/backlog-user-#{github_id}",
        created_at: now - 1000 + index
      )
    end

    repository_ids.each_with_index do |github_id, index|
      create_repository(
        github_id: github_id, full_name: "backlog/repo-#{github_id}", name: "repo-#{github_id}",
        api_url: "https://api.github.com/repos/backlog/repo-#{github_id}",
        created_at: now - 1000 + index
      )
    end
  end

  def stub_backlog_documents!(request_order)
    stub_request(
      :get,
      %r{\Ahttps://api\.github\.com/(?:users/backlog-user-\d+|repos/backlog/repo-\d+)\z}
    ).to_return do |request|
      github_id = request.uri.path[/-(\d+)\z/, 1].to_i
      actor = request.uri.path.start_with?("/users/")
      request_order << [ actor ? :actor : :repository, github_id ]

      body = if actor
        { "id" => github_id, "name" => "Backlog User #{github_id}" }
      else
        { "id" => github_id, "description" => "Backlog repository #{github_id}",
          "language" => "Ruby", "owner" => { "id" => github_id + 100_000 } }
      end

      { status: 200, headers: { "Content-Type" => "application/json" }, body: JSON.generate(body) }
    end
  end

  def live_stubbed_executor(clock:, configuration:)
    Github::RequestExecutor.new(
      transport: Github::Transports::Faraday.new,
      ledger: ledger_for(configuration), mode: :live,
      sleeper: ->(_seconds) { }, clock: clock
    )
  end

  def live_stubbed_runner(executor:, clock:, configuration:)
    selector = Github::Enrichment::CandidateSelector.new(configuration: configuration)
    Github::EnrichmentRunner.new(
      executor: executor, configuration: configuration, clock: clock,
      monotonic: -> { 0.0 }, selector: selector
    )
  end

  def open_window!(executor:, at:)
    stub_request(:get, "https://api.github.com/events?per_page=1").to_return(
      status: 200, body: "[]",
      headers: {
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
      actor_share_used: 0, repository_share_used: 0, enrichment_allowance: 40
    )
  end

  def expect_remaining_backlog(expected_actor_ids, expected_repository_ids)
    actor_rows = GithubActor.where(github_id: actor_ids,
                                   enrichment_status: Enrichable::CANDIDATE_STATUSES)
                            .order(:created_at, :id)
    repository_rows = GithubRepository.where(
      github_id: repository_ids, enrichment_status: Enrichable::CANDIDATE_STATUSES
    ).order(:created_at, :id)

    expect(actor_rows.pluck(:github_id)).to eq(expected_actor_ids)
    expect(repository_rows.pluck(:github_id)).to eq(expected_repository_ids)
    expect(actor_rows.pluck(:enrichment_status, :enrichment_attempts, :next_retry_at, :last_error).uniq)
      .to eq([ [ "pending", 0, nil, nil ] ])
    expect(repository_rows.pluck(:enrichment_status, :enrichment_attempts, :next_retry_at, :last_error).uniq)
      .to eq([ [ "pending", 0, nil, nil ] ])
  end
end
