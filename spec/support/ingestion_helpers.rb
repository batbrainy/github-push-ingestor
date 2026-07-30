# Envelope builders for the ingestion write path (IMPLEMENTATION_PLAN.md §7, §12).
#
# §7's taxonomy needs roughly thirty near-identical envelopes that differ in one field
# each. Written out longhand, the one field that matters disappears into twenty-five lines
# of context, so the base envelope lives here and each example states only its deviation.
#
# The base is corpus event 58000000001 verbatim (fixtures/github/bodies/events/page-1.json),
# so a spec built from it is a spec about the real payload shape and not about an
# invented one. A fresh Hash is returned on every call, so an example may mutate or delete
# from it freely — which is how a *missing* field is expressed, since deep_merge cannot
# remove one.
module IngestionHelpers
  ACTOR_GITHUB_ID = 583_231
  REPOSITORY_GITHUB_ID = 1_296_269

  def well_formed_envelope(overrides = {})
    {
      "id" => "58000000001",
      "type" => Github::Events::PushEventProcessor::EVENT_TYPE,
      "actor" => {
        "id" => ACTOR_GITHUB_ID,
        "login" => "octocat",
        "display_login" => "octocat",
        "gravatar_id" => "",
        "url" => "https://api.github.com/users/octocat",
        "avatar_url" => "https://avatars.githubusercontent.com/u/583231?"
      },
      "repo" => {
        "id" => REPOSITORY_GITHUB_ID,
        "name" => "octocat/Hello-World",
        "url" => "https://api.github.com/repos/octocat/Hello-World"
      },
      "payload" => {
        "repository_id" => REPOSITORY_GITHUB_ID,
        "push_id" => 27_500_000_001,
        "ref" => "refs/heads/main",
        "head" => "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0",
        "before" => "0f9e8d7c6b5a4938271605f4e3d2c1b0a9988776"
      },
      "public" => true,
      "created_at" => "2026-07-29T11:58:12Z"
    }.deep_merge(overrides.deep_stringify_keys)
  end

  # The eight envelopes of page 1, decoded — the exact input every expected count in the
  # integration specs is derived from.
  def corpus_page(name)
    JSON.parse(Rails.root.join("fixtures", "github", "bodies", "events", name).read)
  end
end

RSpec.configure do |config|
  config.include IngestionHelpers
end
