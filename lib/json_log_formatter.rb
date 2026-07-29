require "json"
require "time"

# Structured JSON log formatter (IMPLEMENTATION_PLAN.md §11): one JSON object
# per line so `docker compose logs -f` stays a single coherent stream across
# Rails, Active Job, and application events.
#
# Hash messages merge into the JSON root, which is how application events add
# the plan's common fields (event name, run_id, job ID, GitHub event ID,
# HTTP status, duration, ...) as they arrive in later PRs.
class JsonLogFormatter < ::Logger::Formatter
  SERVICE_NAME = "github-push-ingestor".freeze

  def call(severity, time, _progname, message)
    entry = {
      timestamp: time.utc.iso8601(3),
      level: severity.to_s.downcase,
      service: SERVICE_NAME,
      environment: Rails.env.to_s
    }
    entry.merge!(normalize(message))
    JSON.generate(entry) << "\n"
  end

  private

  def normalize(message)
    case message
    when Hash
      message
    when Exception
      { message: message.message, error_class: message.class.name }
    when String
      { message: message }
    else
      { message: message.inspect }
    end
  end
end
