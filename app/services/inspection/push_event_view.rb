module Inspection
  # A push_events row, shaped for IMPLEMENTATION_PLAN.md §11's inspection endpoints.
  #
  # A module of functions rather than a method on PushEvent, following the convention this
  # codebase already holds twenty times over: there are twenty #to_log methods and not one
  # of them lives on a model. A model owns its columns, its constraints and its idempotent
  # write; how a row is shaped for a reader belongs to the reader — and there are two
  # readers here whose answers deliberately differ, so a single #to_api would need a mode
  # flag on the model.
  #
  # Timestamps go through Github::Ingestion::Report.timestamp, the one formatter this
  # application uses everywhere, so a value in this response and the same value in the JSON
  # log stream are byte-identical and directly greppable.
  module PushEventView
    module_function

    # The list shape, and the single most consequential decision on this endpoint:
    # raw_payload is absent.
    #
    # push_events.raw_payload is jsonb NOT NULL holding a complete GitHub event envelope —
    # kilobytes once the commits array is in it — which puts essentially every row over
    # PostgreSQL's TOAST threshold and out of line. Selecting it for a page is that many
    # extra detoasts, for a field nobody scans a list for, in a response two orders of
    # magnitude larger than the fields anyone reads. No index can soften it, deliberately:
    # ADR 0001 and spec/db/schema_spec.rb both pin the absence of a GIN index. #detail
    # returns it; a list does not.
    def summary(event)
      {
        id: event.github_event_id,
        push_id: event.github_push_id,
        ref: event.ref,
        head_sha: event.head_sha,
        before_sha: event.before_sha,
        # Two different instants, and the gap between them is the ingestion latency §11
        # otherwise only exposes in logs: occurred_at is GitHub's clock, ingested_at is this
        # application's commit.
        occurred_at: Github::Ingestion::Report.timestamp(event.occurred_at),
        ingested_at: Github::Ingestion::Report.timestamp(event.created_at),
        actor: actor(event.github_actor, github_id: event.github_actor_id),
        repository: repository(event.github_repository, github_id: event.github_repository_id)
      }
    end

    # The show shape: the list shape plus the retained payload. §16 makes "raw payload is
    # retained" a functional gate, and this is the endpoint that makes it demonstrable
    # without a psql session.
    def detail(event)
      summary(event).merge(raw_payload: event.raw_payload)
    end

    def page(page)
      {
        data: page.records.map { |event| summary(event) },
        pagination: {
          limit: page.limit,
          count: page.records.length,
          next_cursor: page.next_cursor&.encode
        }
      }
    end

    # Nothing here is .compact-ed, and that is a deliberate departure from the #to_log
    # convention this otherwise follows. A log line drops nil keys because an absent field
    # is noise. A response body must not: "name": null means "this actor is not enriched
    # yet", which is information, and a key that appears and disappears makes every client —
    # and every spec — handle two shapes for one resource. Keys are stable; values may be
    # null.
    #
    # enrichment_status and fetched_at are here for §16's gate that "both actor and
    # repository enrichment demonstrably occur": a reviewer watches them flip from pending
    # to complete while the worker runs, per row, in a browser.
    #
    # github_id is read off the push_events column rather than off the association, so the
    # shape is identical even in the case the foreign keys make unreachable.
    #
    # Deliberately absent: the entity's own raw_payload (one payload per response is
    # enough), and enrichment_attempts / next_retry_at / last_error — last_error can hold a
    # fetch error's message verbatim, and HealthController already establishes the house
    # rule that internals do not cross the HTTP boundary. §11 assigns the aggregate view of
    # those to /status, which ships in this same PR.
    def actor(actor, github_id:)
      {
        github_id: github_id,
        login: actor&.login,
        display_login: actor&.display_login,
        name: actor&.name,
        avatar_url: actor&.avatar_url,
        enrichment_status: actor&.enrichment_status,
        fetched_at: Github::Ingestion::Report.timestamp(actor&.fetched_at)
      }
    end

    def repository(repository, github_id:)
      {
        github_id: github_id,
        full_name: repository&.full_name,
        name: repository&.name,
        description: repository&.description,
        language: repository&.language,
        enrichment_status: repository&.enrichment_status,
        fetched_at: Github::Ingestion::Report.timestamp(repository&.fetched_at)
      }
    end
  end
end
