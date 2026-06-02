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
    def log_path(name)
      path = File.join(@tmp_dir, name)
      File.delete(path) if File.exist?(path)
      path
    end
end
