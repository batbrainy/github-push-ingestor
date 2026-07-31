# Explicit attribute builders instead of a factory library. IMPLEMENTATION_PLAN.md §2A
# pins the test stack to RSpec plus hand-authored fixtures, so no factory gem is
# introduced. Every value is deterministic — there is no randomness to reproduce.
module ModelBuilders
  def frozen_time
    Time.utc(2026, 7, 29, 12, 0, 0)
  end

  # A SHA-1 object name (40 hex chars).
  def sha_40
    "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
  end

  # A SHA-256 object name (64 hex chars) — accepted per plan §7.
  def sha_64
    "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0a1b2c3d4e5f6a7b8c9d0e1f2"
  end

  def actor_attributes(github_id: 1001, **overrides)
    {
      github_id: github_id,
      login: "octocat",
      display_login: "octocat",
      api_url: "https://api.github.com/users/octocat",
      avatar_url: "https://avatars.githubusercontent.com/u/#{github_id}"
    }.merge(overrides)
  end

  def repository_attributes(github_id: 2001, **overrides)
    {
      github_id: github_id,
      full_name: "octocat/hello-world",
      name: "hello-world",
      api_url: "https://api.github.com/repos/octocat/hello-world"
    }.merge(overrides)
  end

  def create_actor(**overrides)
    GithubActor.create!(actor_attributes(**overrides))
  end

  def create_repository(**overrides)
    GithubRepository.create!(repository_attributes(**overrides))
  end

  def push_event_attributes(actor:, repository:, github_event_id: "40000000001", **overrides)
    {
      github_event_id: github_event_id,
      github_push_id: 900_000_001,
      github_repository_id: repository.github_id,
      github_actor_id: actor.github_id,
      ref: "refs/heads/main",
      head_sha: sha_40,
      before_sha: sha_64,
      occurred_at: frozen_time,
      raw_payload: { "type" => "PushEvent", "id" => github_event_id }
    }.merge(overrides)
  end

  def event_source_attributes(**overrides)
    {
      source_type: "github_public_events",
      status: "idle",
      configuration: { "endpoint" => "/events" }
    }.merge(overrides)
  end

  def create_event_source(**overrides)
    EventSource.create!(event_source_attributes(**overrides))
  end

  def quarantined_event_attributes(**overrides)
    {
      payload_fingerprint: "0" * 64,
      raw_payload: { "type" => "PushEvent" },
      first_received_at: frozen_time,
      last_received_at: frozen_time
    }.merge(overrides)
  end

  # The budget table is a constrained singleton, so a spec may only ever create row 1.
  def create_budget(**overrides)
    GithubApiBudget.create!(overrides)
  end

  # create! rather than PushEvent.insert_if_new, deliberately: created_at bounds §11's
  # coverage window, and record_timestamps on the real write path stamps Time.current with
  # no way to override it. create! honours an explicit created_at, which is what lets a
  # spec place a row on either side of the window without travelling time.
  #
  # github_event_id defaults to one constant in push_event_attributes, so a series needs an
  # explicit id per row — the unique index is the arbiter and a silent sequence here would
  # hide that from the example reading it.
  def create_push_event(actor:, repository:, **overrides)
    PushEvent.create!(push_event_attributes(actor: actor, repository: repository, **overrides))
  end
end

RSpec.configure do |config|
  config.include ModelBuilders
end
