# frozen_string_literal: true

require "abstract_unit"
require "active_support/tagged_logging"
require "active_support/logging/logger"
require "fileutils"
require "timeout"

class RactorTaggedLoggingTest < ActiveSupport::TestCase
  setup do
    skip "Ractor::Port is unavailable" unless defined?(Ractor::Port)

    @tmp_dir = File.expand_path("../tmp/ractor_tagged_logging_test", __dir__)
    FileUtils.mkdir_p(@tmp_dir)
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

  test "default mode does not require ractor_safe and writes all messages" do
    path = log_path("default_mode.log")
    logger = ActiveSupport::TaggedLogging.ractor_logger(path)

    10.times { |i| logger.info("message-#{i}") }
    logger.flush

    assert_equal 10, File.read(path).lines.grep(/message-/).size
  ensure
    logger&.close
  end

  test "sync_threshold: nil is equivalent to the default" do
    path = log_path("explicit_nil.log")
    logger = ActiveSupport::TaggedLogging.ractor_logger(path, sync_threshold: nil)

    logger.info("hello")
    logger.flush

    assert_includes File.read(path), "hello"
  ensure
    logger&.close
  end

  test "sync_threshold rejects invalid values before requiring ractor_safe" do
    path = log_path("invalid_threshold.log")

    assert_raises(ArgumentError) { ActiveSupport::TaggedLogging.ractor_logger(path, sync_threshold: 0) }
    assert_raises(ArgumentError) { ActiveSupport::TaggedLogging.ractor_logger(path, sync_threshold: -1) }
    assert_raises(ArgumentError) { ActiveSupport::TaggedLogging.ractor_logger(path, sync_threshold: "1000") }
  end

  test "backpressure writes all messages" do
    require_ractor_safe!
    path = log_path("backpressure.log")
    logger = ActiveSupport::TaggedLogging.ractor_logger(path, sync_threshold: 1)

    10.times { |i| logger.info("message-#{i}") }
    logger.flush

    assert_equal 10, File.read(path).lines.grep(/message-/).size
  ensure
    logger&.close
  end

  test "backpressure keeps tags, log_at, and flush behavior" do
    require_ractor_safe!
    path = log_path("backpressure_features.log")
    logger = ActiveSupport::TaggedLogging.ractor_logger(path, sync_threshold: 1)
    logger.level = Logger::INFO

    logger.tagged("request-id") { logger.info("tagged") }
    logger.log_at(:debug) { logger.debug("inside") }
    logger.debug("outside")
    assert_equal true, logger.flush

    contents = File.read(path)
    assert_includes contents, "[request-id] tagged"
    assert_includes contents, "inside"
    assert_not_includes contents, "outside"
  ensure
    logger&.close
  end

  test "a failing log device does not kill the consumer or raise in the caller" do
    device = FailingDevice.new(fail_writes: true, fail_flush: true)
    logger = ActiveSupport::TaggedLogging.ractor_logger(device)

    Timeout.timeout(5) do
      assert_equal true, logger.info("swallowed")  # write error swallowed
      assert_equal true, logger.flush              # flush error swallowed, no hang/raise

      device.recover!
      logger.info("after recovery")
      logger.flush
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
    def require_ractor_safe!
      require "ractor_safe"
    rescue LoadError
      skip "ractor_safe gem is not available in this bundle"
    end

    def log_path(name)
      path = File.join(@tmp_dir, name)
      File.delete(path) if File.exist?(path)
      path
    end
end
