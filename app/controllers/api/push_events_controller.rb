module Api
  # IMPLEMENTATION_PLAN.md §11's event inspection endpoints.
  #
  # **Never initiates a GitHub request and never consumes budget** — the guarantee §11
  # places on the whole health-and-inspection surface. Structural rather than a promise:
  # this controller holds no executor and no transport, and its only collaborators are
  # Inspection:: value objects over Active Record. The same specs that pin
  # Github::Ingestion::StateSummary pin it — a recording transport that must see no request,
  # and row counts that must not change.
  #
  # Api, not API: config/initializers/inflections.rb registers no acronym, so `namespace
  # :api` camelizes to Api and Zeitwerk expects this path.
  class PushEventsController < ApplicationController
    def index
      page = Inspection::PushEventPage.for(params)

      set_next_link(page)
      render json: Inspection::PushEventView.page(page)
    end

    # :id is github_event_id, not the surrogate primary key, and the two are genuinely
    # ambiguous — real GitHub event ids are numeric strings, so only one reading can be
    # right. §7 keeps the surrogate key out of this application's identity vocabulary
    # entirely (even the foreign keys target github_id), github_event_id is the unique index
    # the whole idempotency story rests on, and it is the identifier §11 puts on every log
    # line — which is what makes "log line -> record" a URL a reviewer can type.
    #
    # find_by! rather than find_by plus an explicit render: ApplicationController maps
    # ActiveRecord::RecordNotFound to the one 404 body, so the miss and the hit share a
    # single code path.
    def show
      event = PushEvent.preload(:github_actor, :github_repository)
                       .find_by!(github_event_id: params[:id])

      render json: { data: Inspection::PushEventView.detail(event) }
    end

    private

    # RFC 8288 — the same relation Github::LinkHeader reads off GitHub's own /events
    # response, emitted here on ours. Deliberately *not* added to that module: its contract
    # is that it only reads, and one header line is not worth inverting it.
    #
    # The body carries next_cursor too. The header is for clients that already speak Link
    # (this application among them); the cursor is what a JSON-only client asserts on.
    def set_next_link(page)
      return if page.next_cursor.nil?

      response.set_header("Link", %(<#{next_page_url(page)}>; rel="next"))
    end

    def next_page_url(page)
      api_push_events_url(
        { limit: page.limit,
          cursor: page.next_cursor.encode,
          actor_id: page.actor_id,
          repository_id: page.repository_id }.compact
      )
    end
  end
end
