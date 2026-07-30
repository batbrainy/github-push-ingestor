require "rails_helper"

# The guarantee CLAUDE.md states — "No live GitHub calls in tests, ever" — asserted
# rather than assumed. Loosening spec/support/webmock.rb fails here instead of quietly
# spending real rate-limit quota from a CI runner.
RSpec.describe "the test suite's network boundary" do
  it "refuses every outbound connection the suite has not stubbed" do
    expect(WebMock.net_connect_allowed?).to be(false)
  end

  it "grants no localhost exemption, because nothing here speaks HTTP to localhost" do
    expect(WebMock::Config.instance.allow_localhost).to be_falsey
  end

  # WebMock hooks Ruby HTTP clients; libpq's socket is not one of them. If this ever
  # fails, the fix is in the boundary configuration, not in the database setup.
  it "still reaches PostgreSQL, because libpq's socket is not one WebMock hooks" do
    expect(ActiveRecord::Base.connection.select_value("SELECT 1")).to eq(1)
  end
end
