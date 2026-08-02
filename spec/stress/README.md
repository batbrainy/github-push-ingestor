# `spec/stress`: why these run in their own process

The specs here open real, concurrent PostgreSQL sessions through the Active Record
connection pool. Everything else in the suite depends on the opposite arrangement, and
`spec/support/advisory_lock_helpers.rb` states it plainly:

> While `use_transactional_fixtures` has the pool pinned, `ConnectionPool#checkout` returns
> the pinned connection to every thread — so a second thread shares the first thread's
> session, and session advisory locks are re-entrant within a session.

That single-session assumption is what lets an example acquire `Github::SourceLock` and
`Github::RequestGate` in the same process without ever contending with itself. A spec that
grows the pool to several genuine sessions breaks the assumption for the whole process,
not just for its own examples: the pool object outlives the example group, and a later
example that takes the request gate while another session holds a ledger row can produce a
true PostgreSQL deadlock (reported, unhelpfully, several files away from the cause).

Cleaning up afterwards is necessary but not sufficient. These specs do delete their rows and
disconnect the pool they grew (`ConcurrencyHelpers#restore_connection_pool!`), and the
suite is still green at most seeds, but "most seeds" is not a property worth shipping in
CI. Running them as their own `rspec` invocation removes the interaction entirely rather
than narrowing it.

Run them with:

```bash
docker compose run --rm test bash -c "bin/rails db:test:prepare && bundle exec rspec spec/stress"
```

Both the compose `test` service and `.github/workflows/ci.yml` run this as a second step
after the main suite, so nothing here is optional or easily forgotten.
