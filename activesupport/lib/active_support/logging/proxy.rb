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

      attr_reader :level, :progname
      attr_accessor :formatter, :silencer
      alias_method :sev_threshold, :level

      def initialize(*args, level: ::Logger::DEBUG, progname: nil, formatter: nil, datetime_format: nil, **logdev_options)
        @actor = Actor.spawn(*args, **logdev_options)

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
        def dispatch(message)
          @actor.async(message)
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
