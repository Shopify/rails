# frozen_string_literal: true

require "logger"
require "active_support/isolated_execution_state"

module ActiveSupport
  # = Ractor-Local Logger
  #
  # A shareable (freezable) logger proxy that creates per-Ractor Logger
  # instances, each with its own IO file descriptor. This allows every
  # Ractor to log independently without contention.
  #
  # Before freeze, capture the original logger's configuration:
  #
  #   ractor_logger = ActiveSupport::RactorLocalLogger.new(Rails.logger)
  #   Rails.logger = ractor_logger
  #   ractor_logger.make_shareable!
  #
  # Each Ractor that calls a log method will lazily open a fresh IO to
  # the same destination (file path or stdout) and create its own
  # Logger + TaggedLogging formatter.
  class RactorLocalLogger
    SEVERITY_METHODS = %i[debug info warn error fatal unknown].freeze

    attr_reader :level, :progname

    def initialize(original_logger)
      @level = original_logger.level

      # Extract the log destination from the original logger.
      inner = if original_logger.respond_to?(:broadcasts)
        original_logger.broadcasts.first
      else
        original_logger
      end

      logdev = inner.instance_variable_get(:@logdev)
      @log_path = logdev&.filename  # nil when logging to STDOUT/STDERR
      @log_fd = logdev&.dev&.fileno rescue nil  # fd number for STDOUT (1) / STDERR (2)

      # Capture formatter class for recreation
      @formatter_class = inner.formatter.class
      @progname = original_logger.progname || "Rails"
    end

    # ── Severity query methods ─────────────────────────────────────
    SEVERITY_METHODS.each do |severity|
      sev_num = ::Logger::Severity.const_get(severity.upcase)
      class_eval <<~RUBY, __FILE__, __LINE__ + 1
        def #{severity}?
          @level <= #{sev_num}
        end

        def #{severity}(message = nil, &block)
          local_logger.#{severity}(message, &block)
        end

        def #{severity}!
          # no-op: level is fixed at freeze time
        end
      RUBY
    end

    # ── Core Logger API ────────────────────────────────────────────
    def add(severity, message = nil, progname = nil, &block)
      local_logger.add(severity, message, progname, &block)
    end
    alias_method :log, :add

    def <<(message)
      local_logger << message
    end

    def flush
      local_logger.flush if local_logger.respond_to?(:flush)
    end

    def close
      # Each Ractor manages its own IO lifetime; no-op on the proxy.
    end

    def formatter
      local_logger.formatter
    end

    def formatter=(fmt)
      local_logger.formatter = fmt
    end

    # ── Silence / thread-safe level ────────────────────────────────
    def silence(severity = ::Logger::ERROR)
      local = local_logger
      if local.respond_to?(:silence)
        local.silence(severity) { yield self }
      else
        yield self
      end
    end

    def local_level
      local_logger.local_level if local_logger.respond_to?(:local_level)
    end

    def local_level=(lvl)
      local_logger.local_level = lvl if local_logger.respond_to?(:local_level=)
    end

    def log_at(level, &block)
      local_logger.log_at(level, &block)
    end

    # ── Tagged logging ─────────────────────────────────────────────
    def push_tags(*tags)
      local_logger.push_tags(*tags) if local_logger.respond_to?(:push_tags)
    end

    def pop_tags(count = 1)
      local_logger.pop_tags(count) if local_logger.respond_to?(:pop_tags)
    end

    def clear_tags!
      local_logger.clear_tags! if local_logger.respond_to?(:clear_tags!)
    end

    def tagged(*tags, &block)
      if local_logger.respond_to?(:tagged)
        local_logger.tagged(*tags, &block)
      else
        yield self
      end
    end

    # ── BroadcastLogger compatibility ──────────────────────────────
    def broadcasts
      [local_logger]
    end

    def level=(lvl)
      # no-op after freeze; per-request level changes use local_level
    end

    alias_method :sev_threshold=, :level=

    def respond_to_missing?(name, include_all = false)
      local_logger.respond_to?(name, include_all) || super
    end

    def method_missing(name, *args, **kwargs, &block)
      if local_logger.respond_to?(name)
        local_logger.send(name, *args, **kwargs, &block)
      else
        super
      end
    end

    private
      def local_logger
        key = :_ractor_local_logger
        IsolatedExecutionState[key] ||= build_logger
      end

      def build_logger
        io = if @log_path
          File.open(@log_path, "a")
        elsif @log_fd
          IO.new(IO.sysopen("/dev/fd/#{@log_fd}", "w"), "w")
        else
          $stderr
        end
        io.sync = true

        logger = ActiveSupport::Logger.new(io)
        logger.level = @level
        logger.progname = @progname
        logger.formatter = @formatter_class.new
        logger = ActiveSupport::TaggedLogging.new(logger)
        logger
      end
  end
end
