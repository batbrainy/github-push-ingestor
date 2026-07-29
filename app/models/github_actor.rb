class GithubActor < ApplicationRecord
  include Enrichable

  has_many :push_events,
           primary_key: :github_id,
           foreign_key: :github_actor_id,
           inverse_of: :github_actor,
           dependent: :restrict_with_error

  # §7 merge rule 1. Envelope values refresh identity fields on any observation,
  # including a duplicate replay — but an envelope upsert must never clear a
  # previously stored enrichment payload or name, so raw_payload, name, and every
  # enrichment_* column are absent from this SET list entirely. COALESCE stops a
  # sparse envelope from blanking a value already known.
  #
  # Envelope-to-stub mapping (§7): actor.login -> login,
  # actor.display_login -> display_login, actor.url -> api_url,
  # actor.avatar_url -> avatar_url.
  IDENTITY_MERGE = <<~SQL.squish
    login         = EXCLUDED.login,
    display_login = COALESCE(EXCLUDED.display_login, github_actors.display_login),
    api_url       = COALESCE(EXCLUDED.api_url,       github_actors.api_url),
    avatar_url    = COALESCE(EXCLUDED.avatar_url,    github_actors.avatar_url),
    updated_at    = EXCLUDED.updated_at
  SQL

  def self.upsert_stub!(github_id:, login:, display_login: nil, api_url: nil,
                        avatar_url: nil, now: Time.current)
    upsert(
      {
        github_id: github_id,
        login: login,
        display_login: display_login,
        api_url: api_url,
        avatar_url: avatar_url,
        created_at: now,
        updated_at: now
      },
      unique_by: :github_id,
      on_duplicate: Arel.sql(IDENTITY_MERGE),
      returning: %w[id]
    ).rows.dig(0, 0)
  end
end
