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
  end
end
