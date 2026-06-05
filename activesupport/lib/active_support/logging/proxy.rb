# frozen_string_literal: true

require "active_support/isolated_execution_state"
require "active_support/logger"
require "active_support/logger_thread_safe_level"
require "active_support/logging/actor"
require "active_support/tagged_logging"
require "logger"

module ActiveSupport
  module Logging # :nodoc:
    class Proxy # :nodoc:
      prepend ActiveSupport::LoggerThreadSafeLevel
      include ActiveSupport::TaggedLogging

      SEVERITY_METHODS = %i[debug info warn error fatal unknown].freeze

      attr_reader :level, :progname, :sync_threshold
      attr_accessor :formatter, :silencer
      alias_method :sev_threshold, :level

      # +sync_threshold+: when +nil+ (the default) the proxy is purely async.
      # When set to a positive Integer, producers switch from async +cast+ to synchronous +call(:write, ...)+ once the
      # actor's in-flight count reaches the threshold, trading producer latency for a bounded queue depth.
      def initialize(*args, sync_threshold: nil, level: ::Logger::DEBUG, progname: nil, formatter: nil, datetime_format: nil, **logdev_options)
        validate_sync_threshold(sync_threshold)
        @sync_threshold = sync_threshold
        @inflight =
          if @sync_threshold
            require_ractor_safe!
            ::RactorSafe::AtomicInteger.new(0)
          end
        @actor = Actor.spawn(*args, inflight: @inflight, **logdev_options)

        config = ActiveSupport::Logger.new(nil, level:, progname:, formatter:, datetime_format:)
        @level = config.level
        @progname = config.progname
        @formatter = config.formatter
        @formatter.extend(ActiveSupport::TaggedLogging::Formatter)
        @formatter.tag_stack # memoize the storage key while mutable, so it survives freezing
        @silencer = true
        @closed = false
      end

      SEVERITY_METHODS.each do |severity|
        severity_number = ::Logger::Severity.const_get(severity.upcase)
        class_eval <<~RUBY, __FILE__, __LINE__ + 1
          def #{severity}?
            level <= #{severity_number}
          end

          def #{severity}(message = nil, &block)
            return true if level > #{severity_number}
            payload = block ? block.call : message
            dispatch(format_message(#{severity_number}, payload, @progname)) unless @closed
            true
          end

          def #{severity}!
            self.level = #{severity_number}
          end
        RUBY
      end

      def add(severity, message = nil, progname = nil, &block)
        severity ||= ::Logger::UNKNOWN
        return true if severity < level

        progname = @progname if progname.nil?
        payload = block ? block.call : (message.nil? ? progname : message)
        dispatch(format_message(severity, payload, progname)) unless @closed
        true
      end
      alias_method :log, :add

      def <<(message)
        dispatch(message.to_s) unless @closed
        self
      end

      def level=(level)
        @level = ::Logger::Severity.coerce(level)
      end
      alias_method :sev_threshold=, :level=

      def silence(severity = ::Logger::ERROR)
        silencer ? log_at(severity) { yield self } : yield(self)
      end

      def flush
        clear_tags!
        @actor.drain unless @closed
        true
      end

      def drain!
        @actor.drain
      end

      def close
        return true if @closed

        @actor.shutdown
        @closed = true unless frozen?
        true
      end

      def initialize_copy(other)
        super
        @local_level_key = :"logger_thread_safe_level_#{object_id}"
        @closed = false
      end

      private
        # The threshold check is a soft limit, multiple producers may observe +threshold - 1+ and briefly exceed it.
        def dispatch(message)
          if @sync_threshold && @inflight.value >= @sync_threshold
            @actor.call(:write, message)
          else
            @inflight&.increment
            @actor.async(message)
          end
        end

        def validate_sync_threshold(value)
          return if value.nil? || (value.is_a?(Integer) && value > 0)
          raise ArgumentError,
            "sync_threshold must be a positive Integer or nil, got #{value.inspect}"
        end

        def require_ractor_safe!
          gem "ractor_safe"
          require "ractor_safe"
        rescue LoadError => error
          raise LoadError, "sync_threshold requires the ractor_safe gem (#{error.message})"
        end

        def format_message(severity, message, progname)
          formatter.call(format_severity(severity), Time.now, progname, message)
        end

        def format_severity(severity)
          ::Logger::SEV_LABEL[severity] || "ANY"
        end
    end
  end
end
