# Solid Queue's database schema lands with PR 8 (IMPLEMENTATION_PLAN.md §13).
# The queue database is declared and prepared from PR 2 onward so the compose
# `setup` service owns preparation of both databases (plan §2A).

ActiveRecord::Schema[8.1].define(version: 0) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
end
