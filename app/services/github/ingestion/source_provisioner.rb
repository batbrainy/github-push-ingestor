module Github
  module Ingestion
    # The event_sources row a run needs, on a clean checkout.
    #
    # Nothing seeds it: db/seeds.rb is empty, and PR 4 wrote down why in
    # Github::BudgetLedger#bootstrap!'s comment — "db/seeds.rb runs only when db:prepare
    # creates a database and db:test:prepare never seeds at all, so a seeded row would exist
    # in development and be absent in test — the worst possible split. A migration is wrong
    # for the same reason, since schema.rb carries no rows." That reasoning applies verbatim
    # here, so PR 5 follows the pattern the ledger established rather than inventing a
    # second answer: lazily, at the point of use.
    #
    # A boot initializer is also wrong: config/initializers/github.rb guarantees its
    # validation "touches no database", which is what lets db:prepare, rails runner and CI's
    # schema load work before anything is migrated.
    #
    # source_type comes from EventSources::Base.for_mode, which PR 4 built for exactly this
    # and says so: "PR 5's runner uses it to provision the event_sources row."
    class SourceProvisioner
      # event_sources.status is NOT NULL with no default and no vocabulary, because PR 6
      # owns the poll state machine (the model's own comment says so). PR 5 has to write
      # *something*, writes this, and never changes it again.
      INITIAL_STATUS = "idle".freeze

      class << self
        # @return [EventSource] the row this mode polls through
        def ensure!(mode: Github.configuration.mode, now: Time.current)
          source_type = EventSources::Base.for_mode(mode).source_type

          existing(source_type) || create(source_type, now) || existing(source_type)
        end

        private

        # Always the lowest id for the type. event_sources.source_type is deliberately not
        # unique — plan §6 anticipates per-repository sources and a PR 3 spec asserts that
        # several rows of one type are allowed — so provisioning cannot be made atomic with
        # an ON CONFLICT clause. Converging on the lowest id is what makes the residual race
        # harmless: two processes that both insert still derive the *same* advisory lock key
        # from the same row afterwards, so the source lock keeps protecting the source. The
        # cost of the race is one extra row and one extra poll attempt, with duplicate
        # events absorbed by github_event_id uniqueness. Adding the constraint belongs to
        # PR 6, which owns this table.
        def existing(source_type)
          EventSource.where(source_type: source_type).order(:id).first
        end

        # configuration stays empty: §6 puts endpoint construction in the adapter, so a URL
        # stored here would be a second source of truth able to disagree with it.
        def create(source_type, now)
          EventSource.create!(source_type: source_type, status: INITIAL_STATUS, enabled: true,
                              configuration: {}, created_at: now, updated_at: now)
        rescue ActiveRecord::RecordNotUnique
          nil
        end
      end
    end
  end
end
