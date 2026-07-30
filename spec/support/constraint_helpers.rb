# Database-level constraint violations need a savepoint.
#
# Specs run inside a transaction (use_transactional_fixtures), and in PostgreSQL a
# failed statement aborts the whole enclosing transaction: every later statement in
# that example fails with PG::InFailedSqlTransaction, including the assertions.
# Running the violation inside a nested transaction makes Rails emit a SAVEPOINT, so
# the failure rolls back to that savepoint and re-raises, leaving the outer
# transaction usable.
module ConstraintHelpers
  # error_class is required on purpose. ActiveRecord::StatementInvalid is the
  # superclass of CheckViolation, NotNullViolation, RecordNotUnique,
  # InvalidForeignKey and ValueTooLong, so defaulting to it would let an example
  # pass on a completely different database failure than the one it names.
  def expect_violation(error_class, &block)
    expect { ActiveRecord::Base.transaction(requires_new: true, &block) }
      .to raise_error(error_class)
  end
end

RSpec.configure do |config|
  config.include ConstraintHelpers
end
