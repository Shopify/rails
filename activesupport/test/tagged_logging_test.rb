# frozen_string_literal: true

require_relative "abstract_unit"
require "active_support/logger"
require "active_support/logging/logger"
require "active_support/tagged_logging"
require "fileutils"
require "timeout"

class TaggedLoggingTest < ActiveSupport::TestCase
  class MyLogger < ::ActiveSupport::Logger
    def flush(*)
      info "[FLUSHED]"
    end
  end

  setup do
    @output = StringIO.new
    @logger = ActiveSupport::TaggedLogging.new(MyLogger.new(@output))
  end

  test "sets logger.formatter if missing and extends it with a tagging API" do
    logger = Logger.new(StringIO.new)
    assert_nil logger.formatter

    other_logger = ActiveSupport::TaggedLogging.new(logger)
    assert_not_nil other_logger.formatter
    assert_respond_to other_logger.formatter, :tagged
  end

  test "tagged once" do
    @logger.tagged("BCX") { @logger.info "Funky time" }
    assert_equal "[BCX] Funky time\n", @output.string
  end

  test "tagged twice" do
    @logger.tagged("BCX") { @logger.tagged("Jason") { @logger.info "Funky time" } }
    assert_equal "[BCX] [Jason] Funky time\n", @output.string
  end

  test "tagged thrice at once" do
    @logger.tagged("BCX", "Jason", "New") { @logger.info "Funky time" }
    assert_equal "[BCX] [Jason] [New] Funky time\n", @output.string
  end

  test "tagged with an array" do
    @logger.tagged(%w(BCX Jason New)) { @logger.info "Funky time" }
    assert_equal "[BCX] [Jason] [New] Funky time\n", @output.string
  end

  test "tagged are flattened" do
    @logger.tagged("BCX", %w(Jason New)) { @logger.info "Funky time" }
    assert_equal "[BCX] [Jason] [New] Funky time\n", @output.string
  end

  test "push and pop tags directly" do
    assert_equal %w(A B C), @logger.push_tags("A", ["B", "  ", ["C"]])
    @logger.info "a"
    assert_equal %w(C), @logger.pop_tags
    @logger.info "b"
    assert_equal %w(B), @logger.pop_tags(1)
    @logger.info "c"
    assert_equal [], @logger.clear_tags!
    @logger.info "d"
    assert_equal "[A] [B] [C] a\n[A] [B] b\n[A] c\nd\n", @output.string
  end

  test "does not strip message content" do
    @logger.info "  Hello"
    assert_equal "  Hello\n", @output.string
  end

  test "provides access to the logger instance" do
    @logger.tagged("BCX") { |logger| logger.info "Funky time" }
    assert_equal "[BCX] Funky time\n", @output.string
  end

  test "tagged once with blank and nil" do
    @logger.tagged(nil, "", "New") { @logger.info "Funky time" }
    assert_equal "[New] Funky time\n", @output.string
  end

  test "keeps each tag in their own thread" do
    @logger.tagged("BCX") do
      Thread.new do
        @logger.info "Dull story"
        @logger.tagged("OMG") { @logger.info "Cool story" }
      end.join
      @logger.info "Funky time"
    end
    assert_equal "Dull story\n[OMG] Cool story\n[BCX] Funky time\n", @output.string
  end

  test "keeps each tag in their own thread even when pushed directly" do
    Thread.new do
      @logger.push_tags("OMG")
      @logger.info "Cool story"
    end.join
    @logger.info "Funky time"
    assert_equal "[OMG] Cool story\nFunky time\n", @output.string
  end

  test "keeps each tag in their own instance" do
    other_output = StringIO.new
    other_logger = ActiveSupport::TaggedLogging.new(MyLogger.new(other_output))
    @logger.tagged("OMG") do
      other_logger.tagged("BCX") do
        @logger.info "Cool story"
        other_logger.info "Funky time"
      end
    end
    assert_equal "[OMG] Cool story\n", @output.string
    assert_equal "[BCX] Funky time\n", other_output.string
  end

  test "does not share the same formatter instance of the original logger" do
    other_logger = ActiveSupport::TaggedLogging.new(@logger)

    @logger.tagged("OMG") do
      other_logger.tagged("BCX") do
        @logger.info "Cool story"
        other_logger.info "Funky time"
      end
    end
    assert_equal "[OMG] Cool story\n[BCX] Funky time\n", @output.string
  end

  test "cleans up the taggings on flush" do
    @logger.tagged("BCX") do
      Thread.new do
        @logger.tagged("OMG") do
          @logger.flush
          @logger.info "Cool story"
        end
      end.join
    end
    assert_equal "[FLUSHED]\nCool story\n", @output.string
  end

  test "mixed levels of tagging" do
    @logger.tagged("BCX") do
      @logger.tagged("Jason") { @logger.info "Funky time" }
      @logger.info "Junky time!"
    end

    assert_equal "[BCX] [Jason] Funky time\n[BCX] Junky time!\n", @output.string
  end

  test "implicit logger instance" do
    @output = StringIO.new
    @logger = ActiveSupport::TaggedLogging.logger(@output)

    @logger.tagged("BCX") { @logger.info "Funky time" }
    assert_equal "[BCX] Funky time\n", @output.string
  end
end

class TaggedLoggingWithoutBlockTest < ActiveSupport::TestCase
  setup do
    @output = StringIO.new
    @logger = ActiveSupport::TaggedLogging.new(Logger.new(@output))
  end

  test "tagged once" do
    @logger.tagged("BCX").info "Funky time"
    assert_equal "[BCX] Funky time\n", @output.string
  end

  test "tagged twice" do
    @logger.tagged("BCX").tagged("Jason").info "Funky time"
    assert_equal "[BCX] [Jason] Funky time\n", @output.string
  end

  test "tagged thrice at once" do
    @logger.tagged("BCX", "Jason", "New").info "Funky time"
    assert_equal "[BCX] [Jason] [New] Funky time\n", @output.string
  end

  test "tagged are flattened" do
    @logger.tagged("BCX", %w(Jason New)).info "Funky time"
    assert_equal "[BCX] [Jason] [New] Funky time\n", @output.string
  end

  test "tagged once with blank and nil" do
    @logger.tagged(nil, "", "New").info "Funky time"
    assert_equal "[New] Funky time\n", @output.string
  end

  test "shares tags across threads" do
    logger = @logger.tagged("BCX")

    Thread.new do
      logger.info "Dull story"
      logger.tagged("OMG").info "Cool story"
    end.join

    logger.info "Funky time"

    assert_equal "[BCX] Dull story\n[BCX] [OMG] Cool story\n[BCX] Funky time\n", @output.string
  end

  test "keeps each tag in their own instance" do
    other_output = StringIO.new
    other_logger = ActiveSupport::TaggedLogging.new(Logger.new(other_output))

    tagged_logger = @logger.tagged("OMG")
    other_tagged_logger = other_logger.tagged("BCX")
    tagged_logger.info "Cool story"
    other_tagged_logger.info "Funky time"

    assert_equal "[OMG] Cool story\n", @output.string
    assert_equal "[BCX] Funky time\n", other_output.string
  end

  test "does not share the same formatter instance of the original logger" do
    other_logger = ActiveSupport::TaggedLogging.new(@logger)

    tagged_logger = @logger.tagged("OMG")
    other_tagged_logger = other_logger.tagged("BCX")
    tagged_logger.info "Cool story"
    other_tagged_logger.info "Funky time"

    assert_equal "[OMG] Cool story\n[BCX] Funky time\n", @output.string
  end

  test "mixed levels of tagging" do
    logger = @logger.tagged("BCX")
    logger.tagged("Jason").info "Funky time"
    logger.info "Junky time!"

    assert_equal "[BCX] [Jason] Funky time\n[BCX] Junky time!\n", @output.string
  end

  test "keeps broadcasting functionality" do
    broadcast_output = StringIO.new
    broadcast_logger = ActiveSupport::BroadcastLogger.new(Logger.new(broadcast_output), @logger)
    logger_with_tags = ActiveSupport::TaggedLogging.new(broadcast_logger)

    tagged_logger = logger_with_tags.tagged("OMG")
    tagged_logger.info "Broadcasting..."

    assert_equal "[OMG] Broadcasting...\n", @output.string
    assert_equal "[OMG] Broadcasting...\n", broadcast_output.string
  end

  test "keeps formatter singleton class methods" do
    plain_output = StringIO.new
    plain_logger = Logger.new(plain_output)
    plain_logger.formatter = Logger::Formatter.new
    plain_logger.formatter.extend(Module.new {
      def crozz_method
      end
    })

    tagged_logger = ActiveSupport::TaggedLogging.new(plain_logger)
    assert_respond_to tagged_logger.formatter, :tagged
    assert_respond_to tagged_logger.formatter, :crozz_method
  end

  test "accepts non-String objects" do
    @logger.tagged("tag") { @logger.info [1, 2, 3] }
    assert_equal "[tag] [1, 2, 3]\n", @output.string
  end

  test "formatter works when frozen" do
    @logger.formatter.freeze
    @logger.info "frozen"
    assert_equal "frozen\n", @output.string
  end
end

class RactorTaggedLoggingTest < ActiveSupport::TestCase
  setup do
    skip "Ractor::Port is unavailable" unless defined?(Ractor::Port)

    # Avoid the "Ractor API is experimental" warning leaking into the test output.
    @original_experimental_warning = Warning[:experimental]
    Warning[:experimental] = false

    @tmp_dir = File.join(__dir__, "tmp", "ractor_tagged_logging_test")
    FileUtils.mkdir_p(@tmp_dir)
  end

  teardown do
    Warning[:experimental] = @original_experimental_warning unless @original_experimental_warning.nil?
  end

  test ".ractor_logger writes through an actor" do
    path = log_path("basic.log")
    logger = ActiveSupport::TaggedLogging.ractor_logger(path)

    logger.info("hello")
    logger.flush

    assert_includes File.read(path), "hello"
  ensure
    logger&.close
  end

  test ".ractor_logger returns a ::Logger subclass wrapped with tagged logging" do
    path = log_path("subclass.log")
    logger = ActiveSupport::TaggedLogging.ractor_logger(path)

    assert_kind_of ActiveSupport::Logging::Logger, logger
    assert_kind_of ::Logger, logger
  ensure
    logger&.close
  end

  test "consumer preserves Logger::LogDevice rotation" do
    path = log_path("rotation.log")
    # Rotate after a tiny size so a few writes trigger a roll-over.
    logger = ActiveSupport::Logging::Logger.new(path, 5, 64)

    20.times { |i| logger.info("rotation-message-#{i}") }
    logger.flush

    rotated = Dir["#{path}.*"]
    assert_not_empty rotated, "expected Logger::LogDevice to rotate the log file"
  ensure
    logger&.close
  end

  test "reopen refreshes the device after the file is rotated externally" do
    path = log_path("reopen.log")
    logger = ActiveSupport::TaggedLogging.ractor_logger(path)

    logger.info("before")
    logger.flush

    rotated = "#{path}.1"
    File.rename(path, rotated) # an external tool moves the file, like logrotate

    logger.reopen # reopen the same path -> a fresh file
    logger.info("after")
    logger.flush

    assert_includes File.read(rotated), "before"
    assert_includes File.read(path), "after"
    assert_not_includes File.read(path), "before"
  ensure
    logger&.close
  end

  test "uses Active Support tagged logging formatter for tags" do
    path = log_path("tags.log")
    logger = ActiveSupport::TaggedLogging.ractor_logger(path)

    logger.tagged("request-id") { logger.info("hello") }
    logger.flush

    assert_includes File.read(path), "[request-id] hello"
  ensure
    logger&.close
  end

  test "uses LocalTagStorage for tagged logger without block" do
    path = log_path("local_tag_storage.log")
    logger = ActiveSupport::TaggedLogging.ractor_logger(path)

    tagged_logger = logger.tagged("job")
    tagged_logger.info("performed")
    logger.info("plain")
    logger.flush

    contents = File.read(path)
    assert_includes contents, "[job] performed"
    assert_includes contents, "plain"
    assert_not_includes contents, "[job] plain"
  ensure
    logger&.close
  end

  test "log_at uses logger-local level storage" do
    path = log_path("log_at.log")
    logger = ActiveSupport::TaggedLogging.ractor_logger(path)
    logger.level = Logger::INFO

    logger.debug("outside")
    logger.log_at(:debug) { logger.debug("inside") }
    logger.debug("outside-again")
    logger.flush

    contents = File.read(path)
    assert_includes contents, "inside"
    assert_not_includes contents, "outside"
    assert_not_includes contents, "outside-again"
  ensure
    logger&.close
  end

  test "log_at works through BroadcastLogger" do
    path = log_path("broadcast_log_at.log")
    ractor_logger = ActiveSupport::TaggedLogging.ractor_logger(path)
    logger = ActiveSupport::BroadcastLogger.new(ractor_logger)
    logger.level = Logger::INFO

    logger.debug("outside")
    logger.log_at(:debug) { logger.debug("inside") }
    logger.debug("outside-again")
    ractor_logger.flush

    contents = File.read(path)
    assert_includes contents, "inside"
    assert_not_includes contents, "outside"
    assert_not_includes contents, "outside-again"
  ensure
    ractor_logger&.close
  end

  test "silence uses logger-local level storage" do
    path = log_path("silence.log")
    logger = ActiveSupport::TaggedLogging.ractor_logger(path)
    logger.level = Logger::DEBUG

    logger.silence(Logger::ERROR) { logger.info("quiet-line") }
    logger.info("loud-line")
    logger.flush

    contents = File.read(path)
    assert_includes contents, "loud-line"
    assert_not_includes contents, "quiet-line"
  ensure
    logger&.close
  end

  test "ractor logger actor is shareable" do
    path = log_path("shareable_actor.log")
    actor = ActiveSupport::Logging::Actor.spawn(path)

    assert Ractor.shareable?(actor)

    actor.async("hello\n")
    actor.flush

    assert_includes File.read(path), "hello"
  ensure
    actor&.shutdown
  end

  test "ractor logger can be made shareable" do
    path = log_path("shareable.log")
    logger = ActiveSupport::TaggedLogging.ractor_logger(path)

    Ractor.make_shareable(logger)

    assert Ractor.shareable?(logger)
    logger.tagged("shareable") { logger.info("hello") }
    logger.flush

    assert_includes File.read(path), "[shareable] hello"
  ensure
    logger&.close
  end

  test "a shareable logger logs from a non-main Ractor" do
    path = log_path("from_ractor.log")
    logger = ActiveSupport::TaggedLogging.ractor_logger(path)
    Ractor.make_shareable(logger)

    Ractor.new(logger) do |lg|
      lg.tagged("request-id") { lg.info("from ractor") }
      :done
    end.value

    logger.flush

    assert_includes File.read(path), "[request-id] from ractor"
  ensure
    logger&.close
  end

  test "a failing log device does not kill the consumer or raise in the caller" do
    device = FailingDevice.new(fail_writes: true, fail_flush: true)
    logger = ActiveSupport::TaggedLogging.ractor_logger(device)

    # The device write/flush failures are reported to stderr like the stock
    # Logger does; capture it so the expected noise stays out of the test output.
    capture_io do
      Timeout.timeout(5) do
        assert_equal true, logger.info("swallowed")  # write error swallowed
        assert_equal true, logger.flush              # flush error swallowed, no hang/raise

        device.recover!
        logger.info("after recovery")
        logger.flush
      end
    end

    assert_includes device.written.join, "after recovery"
  ensure
    logger&.close
  end

  test "a dead consumer degrades to a no-op instead of hanging" do
    actor = ActiveSupport::Logging::Actor.spawn(NullDevice.new)
    actor.instance_variable_get(:@port).close # simulate a consumer that has gone away

    Timeout.timeout(5) do
      assert_nil actor.async("dropped\n")
      assert_nil actor.flush
    end
  end

  class FailingDevice
    attr_reader :written

    def initialize(fail_writes:, fail_flush:)
      @fail_writes = fail_writes
      @fail_flush = fail_flush
      @written = []
    end

    def recover!
      @fail_writes = false
      @fail_flush = false
    end

    def write(message)
      raise IOError, "write boom" if @fail_writes
      @written << message
    end

    def flush
      raise IOError, "flush boom" if @fail_flush
    end

    def close; end
  end

  NullDevice = ActiveSupport::Logging::Actor::NullDevice

  private
    def log_path(name)
      path = File.join(@tmp_dir, name)
      File.delete(path) if File.exist?(path)
      path
    end
end
