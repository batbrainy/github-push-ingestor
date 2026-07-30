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

  # script/probe_304.sh deliberately makes live, unauthenticated requests to
  # api.github.com — it is the evidence §10 makes a required gate for PR 6. It shells out
  # to curl, a separate process WebMock cannot intercept, so the boundary that matters is
  # not "it is stubbed" but "nothing here runs it." That is trivially checkable, so it is
  # checked rather than trusted: a spec, a CI step, or a bin/ci step that reached for it
  # would spend a CI runner's quota on every push.
  it "keeps the live probe out of the suite, out of CI, and out of bin/ci" do
    reachable = Dir[Rails.root.join("spec/**/*.rb"), Rails.root.join(".github/workflows/*.yml")] +
                [ Rails.root.join("config/ci.rb").to_s, Rails.root.join("bin/ci").to_s ]

    referencing = reachable.select do |path|
      File.file?(path) && File.basename(path) != File.basename(__FILE__) &&
        File.read(path).include?("probe_304")
    end

    expect(referencing).to be_empty
  end
end
