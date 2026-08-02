# Run using bin/ci

CI.run do
  step "Setup", "bin/setup --skip-server"

  # Isolated test databases, never the development ones (plan §2A).
  step "Tests: Prepare databases", "bin/rails db:test:prepare"
  step "Tests: RSpec", "bundle exec rspec"

  # The suite loads Rails through rails_helper, so it cannot exercise the one-shot's own
  # boot path — its shebang, its config/environment require, and any stdlib the harness
  # happens to have loaded already. Running it once is the only thing that does. Fixture
  # mode, so it touches no network.
  step "Tests: One-shot ingestion smoke", "env RAILS_ENV=test GITHUB_MODE=fixture bin/ingest"

  # Ordered after the ingestion smoke on purpose, and worth more than its own boot check:
  # that step has already initialized the rate-limit window and persisted the corpus's
  # stub entities, so this one exercises the whole §12 chain — poll, persist, stub,
  # enrich — across two real processes, offline and deterministically.
  step "Tests: One-shot enrichment smoke",
       "env RAILS_ENV=test GITHUB_MODE=fixture SEARCH_PACING_SECONDS=0 bin/enrich --limit 6"

  # Solid Queue's own validator over config/queue.yml and config/recurring.yml. Starts no
  # process; catches an unparseable schedule or a task naming a class that does not exist.
  step "Tests: Queue configuration", "env RAILS_ENV=test bin/rails solid_queue:check"

  # The supervisor's own boot path, for the same reason the two smokes above exist — nothing
  # else runs bin/jobs. It proves boot, recurring-task registration and a clean TERM, not that
  # a tick fired: the schedule is 60 seconds and waiting for one would treble the step. Fixture
  # mode is mandatory — this boots a real scheduler in a process WebMock cannot see.
  step "Tests: Worker supervisor smoke",
       "env RAILS_ENV=test GITHUB_MODE=fixture timeout --preserve-status --signal=TERM 20 bin/jobs"

  step "Style: Ruby", "bin/rubocop"

  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"


  # Optional: set a green GitHub commit status to unblock PR merge.
  # Requires the `gh` CLI and `gh extension install basecamp/gh-signoff`.
  # if success?
  #   step "Signoff: All systems go. Ready for merge and deploy.", "gh signoff"
  # else
  #   failure "Signoff: CI failed. Do not merge or deploy.", "Fix the issues and try again."
  # end
end
