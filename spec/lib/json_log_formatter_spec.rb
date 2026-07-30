require "rails_helper"

RSpec.describe JsonLogFormatter do
  subject(:formatter) { described_class.new }

  it "emits one JSON object per line with the common fields" do
    line = formatter.call("INFO", Time.utc(2026, 7, 29, 12, 0, 0), nil, "hello")

    expect(line).to end_with("\n")
    expect(JSON.parse(line)).to eq(
      "timestamp" => "2026-07-29T12:00:00.000Z",
      "level" => "info",
      "service" => "github-push-ingestor",
      "environment" => "test",
      "message" => "hello"
    )
  end

  it "merges hash messages into the JSON root for structured events" do
    line = formatter.call("INFO", Time.now, nil, { event: "ingestion.run_started", run_id: "1e3d" })

    expect(JSON.parse(line)).to include("event" => "ingestion.run_started", "run_id" => "1e3d")
  end

  it "captures exception class and message" do
    line = formatter.call("ERROR", Time.now, nil, StandardError.new("boom"))

    expect(JSON.parse(line)).to include(
      "level" => "error",
      "error_class" => "StandardError",
      "message" => "boom"
    )
  end

  it "downcases severity and stringifies non-string payloads" do
    line = formatter.call("WARN", Time.now, nil, [ 1, 2 ])

    expect(JSON.parse(line)).to include("level" => "warn", "message" => "[1, 2]")
  end

  it "never lets payloads overwrite the formatter-owned fields" do
    line = formatter.call("INFO", Time.utc(2026, 7, 29), nil,
                          { "level" => "error", service: "spoof", timestamp: "1970-01-01", environment: "prod", event: "x" })

    expect(JSON.parse(line)).to include(
      "level" => "info",
      "service" => "github-push-ingestor",
      "timestamp" => "2026-07-29T00:00:00.000Z",
      "environment" => "test",
      "event" => "x"
    )
  end
end
