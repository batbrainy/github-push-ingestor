require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
# require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
# require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

require_relative "../lib/json_log_formatter"

module GithubPushIngestor
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # json_log_formatter is required explicitly above (needed before the
    # autoloader is ready), so it is excluded from autoloading.
    config.autoload_lib(ignore: %w[assets tasks json_log_formatter.rb])

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true

    # Structured JSON logging to stdout in every environment, one stream for
    # Rails, Active Job, and application events (IMPLEMENTATION_PLAN.md §11).
    logger = ActiveSupport::Logger.new($stdout)
    logger.formatter = JsonLogFormatter.new
    config.logger = logger
    config.log_level = ENV.fetch("LOG_LEVEL", "info")

    # Solid Queue is the job backend (§2A), and it lives in its own `queue` database inside
    # the same PostgreSQL container — config/database.yml has declared that database since
    # PR 2, and db/queue_migrate carries its schema.
    #
    # Configured here rather than in config/environments/production.rb, where the installer
    # put it, for the same reason logging is configured here: the `worker` container runs
    # RAILS_ENV=development by default, so development is the environment reviewers actually
    # exercise. A job backend that differed by environment would make PR 8's recovery
    # behaviour untestable exactly where it runs. config/environments/test.rb overrides the
    # adapter with :test — §2A's "ordinary specs use Active Job's test adapter; only
    # dedicated queue integration tests touch the queue test database".
    config.active_job.queue_adapter = :solid_queue
    config.solid_queue.connects_to = { database: { writing: :queue } }

    # Its polling SELECTs would otherwise be the loudest thing in the stream: two processes
    # asking for work every second against ~12 ingestion runs an hour (§11 requires the
    # events reviewers trace not to be buried).
    config.solid_queue.silence_polling = true

    # Active Job's own subscriber, at warn. Its "Performing X (Job ID: ...)" pair is an
    # unstructured `message` string in a JSON stream, it says nothing ApplicationJob's
    # job.started/job.completed lines do not say with real fields, and at ~120 jobs an hour
    # it would be two thirds of the INFO stream. Warn rather than silence: the framework's
    # own error and retry lines still land, in the same format, on the same stream.
    active_job_logger = ActiveSupport::Logger.new($stdout)
    active_job_logger.formatter = JsonLogFormatter.new
    active_job_logger.level = :warn
    config.active_job.logger = active_job_logger

    # Derived from §2A's pinned defaults, the way Github::RequestGate::WAIT_SECONDS is:
    # HTTP_OPEN_TIMEOUT_SECONDS (5) + HTTP_READ_TIMEOUT_SECONDS (15) is the longest an
    # attempt that already holds the request gate can still be running, so a TERM waits that
    # long for in-flight work and no longer. docker-compose.yml pairs it with
    # stop_grace_period: 30s, leaving margin for the supervisor to reap its children.
    #
    # A job still *waiting* for the gate has reserved nothing and is safe to kill: §8's
    # at-least-once execution with idempotent writes is what makes that true, and both
    # advisory locks die with the session.
    config.solid_queue.shutdown_timeout = 20.seconds
  end
end
