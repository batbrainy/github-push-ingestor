source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.3"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"

# The Active Job backend pinned by IMPLEMENTATION_PLAN.md §2A: PostgreSQL-backed, no
# Redis, recurring tasks drive polling, and it runs in its own `queue` database inside the
# same Postgres container (config/database.yml declares it; db/queue_migrate carries its
# schema). That separation is what makes §8 step 10's post-commit enqueue necessary — an
# enqueue cannot join the business transaction, so the committed entity rows are the
# durable record of pending work and Github::Enrichment::Dispatch is only a hint.
gem "solid_queue", "~> 1.5"

# HTTP client for every live GitHub request, pinned by IMPLEMENTATION_PLAN.md §2A.
# Reached only through Github::Transports::Faraday, and configured with no middleware:
# retries and redirects belong to Github::RequestExecutor because every attempt
# re-reserves budget and every redirect target is re-validated (§10, docs/adr/0003).
gem "faraday", "~> 2.14"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
# gem "jbuilder"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Use Rack CORS for handling Cross-Origin Resource Sharing (CORS), making cross-origin Ajax possible
# gem "rack-cors"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # RSpec is the test framework pinned by IMPLEMENTATION_PLAN.md §2A
  gem "rspec-rails"

  # Refuses every outbound socket the suite has not stubbed, so no spec can reach live
  # GitHub (§12, CLAUDE.md). Pairs with the static corpus under fixtures/github/.
  gem "webmock", require: false

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end
