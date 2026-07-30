require "rails_helper"

RSpec.describe Github::RetryPolicy do
  subject(:policy) { described_class.new(max_attempts: 2, random: Random.new(1234)) }

  describe "#retry?" do
    it "retries a 5xx, which is one of the two cases plan §10 names" do
      expect(policy.retry?(classification: :server_error, attempt: 0)).to be(true)
    end

    it "retries a network-level failure, which is the other" do
      expect(policy.retry?(classification: :transport_error, attempt: 0)).to be(true)
    end

    # Every attempt is its own reservation against sixty requests an hour, so the cap
    # is a budget control, not just a politeness control.
    it "stops at MAX_HTTP_RETRIES, because each attempt spends real quota" do
      expect(policy.retry?(classification: :server_error, attempt: 1)).to be(true)
      expect(policy.retry?(classification: :server_error, attempt: 2)).to be(false)
    end

    it "honours a configuration that disables retries entirely" do
      expect(described_class.new(max_attempts: 0).retry?(classification: :server_error, attempt: 0))
        .to be(false)
    end

    it "never retries anything else" do
      not_retryable = Github::FetchResult::CLASSIFICATIONS - %i[ server_error transport_error ]

      not_retryable.each do |classification|
        expect(policy.retry?(classification: classification, attempt: 0))
          .to be(false), "expected #{classification} not to be retried"
      end
    end
  end

  describe "#backoff_seconds" do
    it "grows exponentially, so a struggling endpoint gets progressively more room" do
      expect(policy.backoff_seconds(0)).to be < policy.backoff_seconds(1)
      expect(policy.backoff_seconds(1)).to be < policy.backoff_seconds(2)
    end

    it "stays within its jitter band, so backoff never becomes unbounded" do
      3.times do |attempt|
        base = described_class::RETRY_BASE_DELAY_SECONDS * (2**attempt)

        expect(policy.backoff_seconds(attempt))
          .to be_between(base, base * (1 + described_class::RETRY_JITTER_FRACTION))
      end
    end

    # The worker and the one-shot can hit the same failing endpoint at once; identical
    # backoffs would keep them in lockstep through the whole retry sequence.
    it "jitters, so two processes retrying together do not stay synchronised" do
      one = described_class.new(random: Random.new(1)).backoff_seconds(0)
      two = described_class.new(random: Random.new(2)).backoff_seconds(0)

      expect(one).not_to eq(two)
    end

    # The Random is injected precisely so the schedule can be asserted without a sleep
    # anywhere in the suite.
    it "is reproducible for a given seed, so the schedule is testable without sleeping" do
      first = described_class.new(random: Random.new(99)).backoff_seconds(1)
      second = described_class.new(random: Random.new(99)).backoff_seconds(1)

      expect(first).to eq(second)
    end
  end

  describe ".disposition" do
    it "defers what was never attempted, so a busy system is not a failing one" do
      described_class::DEFERRED_ERRORS.each do |klass|
        expect(described_class.disposition(build_error(klass))).to eq(:defer),
                                                                   "expected #{klass} to defer"
      end
    end

    it "retries the two network-level failures" do
      described_class::RETRYABLE_ERRORS.each do |klass|
        expect(described_class.disposition(klass.new)).to eq(:retry), "expected #{klass} to retry"
      end
    end

    # §10 lists only 5xx and network timeouts as retryable. A certificate failure will
    # not clear inside two attempts, it may be an interception attempt, and each retry
    # spends quota that polling needs.
    it "does not retry a TLS failure" do
      expect(described_class.disposition(Github::Errors::TlsError.new)).to eq(:permanent)
    end

    # Fixture mode fails closed (§6). Retrying a miss would spend the retry budget
    # rediscovering that the corpus still does not define the URL.
    it "does not retry a fixture miss" do
      expect(described_class.disposition(Github::Errors::FixtureMiss.new)).to eq(:permanent)
    end

    it "treats a refused URL as permanent, which PR 7 maps to permanent_failure" do
      violation = Github::Errors::UrlPolicyViolation.new("http://evil.test", [ :host_not_allowed ])

      expect(described_class.disposition(violation)).to eq(:permanent)
    end

    # A future error class must not fall through to an undefined entity outcome, so
    # every constant under Github::Errors is required to have an answer.
    it "gives every declared error a disposition from the closed vocabulary" do
      error_classes = Github::Errors.constants
        .map { |name| Github::Errors.const_get(name) }
        .select { |constant| constant.is_a?(Class) && constant <= StandardError }

      error_classes.each do |klass|
        expect(described_class::DISPOSITIONS).to include(described_class.disposition(build_error(klass))),
                                                         "expected #{klass} to have a disposition"
      end
    end
  end

  describe ".classification_for" do
    it "reports a retryable failure as a transport error the retry loop understands" do
      expect(described_class.classification_for(Github::Errors::RequestTimeout.new))
        .to eq(:transport_error)
    end

    it "reports everything else as permanent, so the loop stops" do
      expect(described_class.classification_for(Github::Errors::TlsError.new)).to eq(:permanent_error)
    end
  end

  # Some error classes take constructor arguments; this keeps the iteration honest
  # rather than skipping them.
  def build_error(klass)
    case klass.name
    when "Github::Errors::UrlPolicyViolation" then klass.new("https://api.github.com", [ :blank ])
    when "Github::Errors::BudgetExhausted" then klass.new(:poll, :class_allowance_exhausted)
    else klass.new
    end
  end
end
