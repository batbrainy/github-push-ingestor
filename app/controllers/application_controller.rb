class ApplicationController < ActionController::API
  # One error body for every failure this application returns, and never a framework
  # default.
  #
  # This is not tidiness. config.consider_all_requests_local is true in development *and*
  # test, and this is an api_only application, so config.debug_exception_response_format
  # defaults to :api — meaning an unrescued exception is rendered by
  # ActionDispatch::DebugExceptions as JSON carrying the exception class **and its full
  # backtrace**. HealthController already refuses to leak that way, reporting only
  # e.class.name; these two handlers hold the same line for IMPLEMENTATION_PLAN.md §11's
  # inspection endpoints, and give clients one error shape instead of two.
  #
  # The 404 message is fixed rather than read off the exception, for the same reason.

  rescue_from ActiveRecord::RecordNotFound do
    render_error(:not_found, "not_found", "no record matches that identifier")
  end

  # The message is safe to echo: Inspection::Errors::InvalidParameter builds it from the
  # parameter *name* and a fixed phrase, never from the value the client sent.
  rescue_from Inspection::Errors::InvalidParameter do |error|
    render_error(:bad_request, "invalid_parameter", error.message, parameter: error.parameter)
  end

  private

  def render_error(status, code, message, **details)
    render json: { error: { code: code, message: message, **details } }, status: status
  end
end
