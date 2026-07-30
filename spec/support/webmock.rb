require "webmock/rspec"

# IMPLEMENTATION_PLAN.md §12 and CLAUDE.md: no live GitHub calls in tests, ever.
#
# `webmock/rspec` enables WebMock for the suite and resets stubs after every example,
# but it does not decide the connection policy — this call does. Localhost is closed
# rather than left open: request specs reach the application through Rack, not through
# a socket, so this application has no local HTTP dependency to exempt.
#
# PostgreSQL is unaffected. WebMock hooks Ruby HTTP client libraries; the pg gem talks
# to the server through libpq's own socket, which WebMock never sees. Solid Queue
# (PR 8) is PostgreSQL-backed for the same reason.
WebMock.disable_net_connect!(allow_localhost: false)
