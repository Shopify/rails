# frozen_string_literal: true

require "abstract_unit"
require "active_support/tagged_logging"
require "active_support/logging/proxy"
require "fileutils"

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
    logger.drain!

    assert_includes File.read(path), "hello"
  ensure
    logger&.close
  end

  test "consumer preserves Logger::LogDevice rotation" do
    path = log_path("rotation.log")
    # Rotate after a tiny size so a few writes trigger a roll-over.
    logger = ActiveSupport::Logging::Proxy.new(path, 5, 64)

    20.times { |i| logger.info("rotation-message-#{i}") }
    logger.drain!

    rotated = Dir["#{path}.*"]
    assert_not_empty rotated, "expected Logger::LogDevice to rotate the log file"
  ensure
    logger&.close
  end

  test "uses Active Support tagged logging formatter for tags" do
    path = log_path("tags.log")
    logger = ActiveSupport::TaggedLogging.ractor_logger(path)

    logger.tagged("request-id") { logger.info("hello") }
    logger.drain!

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
    logger.drain!

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
    logger.drain!

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
    ractor_logger.drain!

    contents = File.read(path)
    assert_includes contents, "inside"
    assert_not_includes contents, "outside"
    assert_not_includes contents, "outside-again"
  ensure
    ractor_logger&.close
  end

  test "ractor logger actor is shareable" do
    path = log_path("shareable_actor.log")
    actor = ActiveSupport::Logging::Actor.spawn(path)

    assert Ractor.shareable?(actor)

    actor.async("hello\n")
    actor.drain

    assert_includes File.read(path), "hello"
  ensure
    actor&.shutdown
  end

  test "default mode does not require ractor_safe and writes all messages" do
    path = log_path("default_mode.log")
    logger = ActiveSupport::TaggedLogging.ractor_logger(path)

    assert_nil logger.sync_threshold
    10.times { |i| logger.info("message-#{i}") }
    logger.drain!

    assert_equal 10, File.read(path).lines.grep(/message-/).size
  ensure
    logger&.close
  end

  test "sync_threshold: nil is equivalent to the default" do
    path = log_path("explicit_nil.log")
    logger = ActiveSupport::TaggedLogging.ractor_logger(path, sync_threshold: nil)

    assert_nil logger.sync_threshold
    logger.info("hello")
    logger.drain!

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

    assert_equal 1, logger.sync_threshold
    10.times { |i| logger.info("message-#{i}") }
    logger.drain!

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
    logger.drain!

    contents = File.read(path)
    assert_includes contents, "[request-id] tagged"
    assert_includes contents, "inside"
    assert_not_includes contents, "outside"
  ensure
    logger&.close
  end

  test "ractor logger proxy can be made shareable" do
    path = log_path("shareable.log")
    logger = ActiveSupport::TaggedLogging.ractor_logger(path)

    Ractor.make_shareable(logger)

    assert Ractor.shareable?(logger)
    logger.tagged("shareable") { logger.info("hello") }
    logger.drain!

    assert_includes File.read(path), "[shareable] hello"
  ensure
    logger&.close
  end

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
