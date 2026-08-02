class GithubRepository < ApplicationRecord
  include Enrichable

  has_many :push_events,
           primary_key: :github_id,
           foreign_key: :github_repository_id,
           inverse_of: :github_repository,
           dependent: :restrict_with_error

  validates :full_name, presence: true

  # §7 merge rule 1, same non-clobbering shape as GithubActor::IDENTITY_MERGE:
  # raw_payload, description, language, and owner_github_id are enrichment-owned and
  # therefore absent from this SET list.
  #
  # Envelope-to-stub mapping (§7): event.repo.name is the qualified owner/repository
  # form and maps to full_name — it is deliberately not equated with the enriched
  # short name. name is the final segment of full_name, so it is envelope-derived
  # (§7's enrichment list excludes it) and belongs here under COALESCE.
  # Assignments use the same freshness-guarded COALESCE shape as
  # GithubActor::IDENTITY_MERGE — see the explanation there.
  IDENTITY_MERGE = <<~SQL.squish
    full_name = COALESCE(
      CASE WHEN EXCLUDED.updated_at >= github_repositories.updated_at
           THEN EXCLUDED.full_name END,
      github_repositories.full_name),
    name = COALESCE(
      CASE WHEN EXCLUDED.updated_at >= github_repositories.updated_at
           THEN EXCLUDED.name END,
      github_repositories.name),
    owner_login = COALESCE(
      CASE WHEN EXCLUDED.updated_at >= github_repositories.updated_at
           THEN EXCLUDED.owner_login END,
      github_repositories.owner_login),
    api_url = COALESCE(
      CASE WHEN EXCLUDED.updated_at >= github_repositories.updated_at
           THEN EXCLUDED.api_url END,
      github_repositories.api_url),
    updated_at = GREATEST(github_repositories.updated_at, EXCLUDED.updated_at)
  SQL

  # See GithubActor.upsert_stub! — the explicit validate! keeps a malformed envelope
  # from aborting the ingest transaction before it can be quarantined.
  def self.upsert_stub!(github_id:, full_name:, name: nil, api_url: nil,
                        now: Time.current)
    owner_login = full_name.to_s.split("/", 2).first if full_name.to_s.include?("/")
    new(github_id: github_id, full_name: full_name, name: name,
        api_url: api_url).validate!

    upsert(
      {
        github_id: github_id,
        full_name: full_name,
        name: name,
        owner_login: owner_login,
        api_url: api_url,
        created_at: now,
        updated_at: now
      },
      unique_by: :github_id,
      on_duplicate: Arel.sql(IDENTITY_MERGE),
      returning: %w[id]
    ).rows.dig(0, 0)
  end
end
