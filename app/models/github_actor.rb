class GithubActor < ApplicationRecord
  include Enrichable

  has_many :push_events,
           primary_key: :github_id,
           foreign_key: :github_actor_id,
           inverse_of: :github_actor,
           dependent: :restrict_with_error

  validates :login, presence: true

  # §7 merge rule 1. Envelope values refresh identity fields on any observation,
  # including a duplicate replay — but an envelope upsert must never clear a
  # previously stored enrichment payload or name, so raw_payload, name, and every
  # enrichment_* column are absent from this SET list entirely.
  #
  # Envelope-to-stub mapping (§7): actor.login -> login,
  # actor.display_login -> display_login, actor.url -> api_url,
  # actor.avatar_url -> avatar_url.
  #
  # Every assignment has the same shape, which resolves two problems at once:
  #
  #   COALESCE(CASE WHEN <envelope is fresh> THEN EXCLUDED.col END, <stored col>)
  #
  # A stale envelope makes the CASE yield NULL, so COALESCE keeps the stored value —
  # an older observation can never overwrite identity captured from a newer one. That
  # matters because sources commit independently and events arrive late (documented
  # 30s-6h latency), and because updated_at is monotonic: without this guard the row
  # could hold the older envelope's identity while updated_at claimed the newer
  # observation. A fresh envelope that simply omits an optional field also yields
  # NULL, so the same COALESCE stops a sparse envelope from blanking a known value.
  #
  # The comparison is >=, so two observations sharing an instant let the later write
  # win rather than being discarded as stale.
  IDENTITY_MERGE = <<~SQL.squish
    login = COALESCE(
      CASE WHEN EXCLUDED.updated_at >= github_actors.updated_at
           THEN EXCLUDED.login END,
      github_actors.login),
    display_login = COALESCE(
      CASE WHEN EXCLUDED.updated_at >= github_actors.updated_at
           THEN EXCLUDED.display_login END,
      github_actors.display_login),
    api_url = COALESCE(
      CASE WHEN EXCLUDED.updated_at >= github_actors.updated_at
           THEN EXCLUDED.api_url END,
      github_actors.api_url),
    avatar_url = COALESCE(
      CASE WHEN EXCLUDED.updated_at >= github_actors.updated_at
           THEN EXCLUDED.avatar_url END,
      github_actors.avatar_url),
    updated_at = GREATEST(github_actors.updated_at, EXCLUDED.updated_at)
  SQL

  # The explicit validate! mirrors PushEvent.insert_if_new: upsert goes straight to
  # PostgreSQL, so without it a nil github_id or login would surface as a
  # NotNullViolation that aborts the ingest transaction, taking the rest of the batch
  # with it instead of letting the caller quarantine one malformed envelope.
  def self.upsert_stub!(github_id:, login:, display_login: nil, api_url: nil,
                        avatar_url: nil, now: Time.current)
    new(github_id: github_id, login: login, display_login: display_login,
        api_url: api_url, avatar_url: avatar_url).validate!

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
