# syntax=docker/dockerfile:1

# Ruby pinned exactly per IMPLEMENTATION_PLAN.md §2A — the same pin lives in
# .ruby-version; CI inherits it when the real suite takes over CI in PR 3.
FROM ruby:3.4.10-slim

WORKDIR /rails

# libpq for the pg gem, curl for container health checks, the rest for
# building native gems.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential curl git libpq-dev libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# All gem groups are installed: one image serves web, setup, and the test
# suite (compose topology, plan §2A). Frozen mode makes the build fail loudly
# if Gemfile drifts from the committed Gemfile.lock instead of silently
# re-resolving inside the image.
ENV BUNDLE_FROZEN="1"
COPY Gemfile Gemfile.lock .ruby-version ./
RUN bundle install && \
    rm -rf "${GEM_HOME}/cache"

COPY . .

# Run as a non-root user. log/ and tmp/ are written at runtime; db/ must be
# writable because `db:prepare` dumps schema files after running migrations.
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    chown -R rails:rails /rails/log /rails/tmp /rails/db
USER 1000:1000

EXPOSE 3000
# Puma directly, not `bin/rails server`: the rails wrapper writes
# tmp/pids/server.pid, and as PID 1 in a container a stale pid file after an
# ungraceful kill blocks every restart ("A server is already running"),
# defeating the declared `unless-stopped` crash recovery. config/puma.rb sets
# no pidfile unless PIDFILE is explicitly requested.
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
