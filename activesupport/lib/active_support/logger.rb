# frozen_string_literal: true

require "active_support/logger_silence"
require "active_support/logger_thread_safe_level"
require "logger"
require "monitor"

# +Logger::LogDevice+ includes +MonitorMixin+, whose +@mon_data+ ivar holds a
# non-shareable +Monitor+. After Ruby's +bdddfccc01+ MonitorMixin no longer
# clears that ivar on +freeze+, so deep-freezing any +Logger+ (including
# +Rails.logger+ via +ractorize!+) raises +Ractor::Error+ on the device.
#
# Opt the device's monitor out of locking on +freeze+. This is the use case
# +MonitorMixin#unsynchronize!+ is designed for: the synchronize-protected
# state on the device (its +@dev+/+@filename+/etc.) is immutable after
# +freeze+, and the only side effect inside +synchronize+ blocks is a single
# +IO#write+ per log line. POSIX +write(2)+ on a regular file or terminal is
# atomic up to +PIPE_BUF+ (typically 4 KiB), which is larger than any log
# line Rails emits, so log writes from multiple Ractors do not interleave in
# practice even without the lock. The +shift_log+ rotation path is the only
# multi-step critical section, but it is not exercised on a frozen production
# logger (rotation requires writes to +@dev+, which the surrounding code
# never invokes after freeze).
#
# Loading this file therefore opts +Logger::LogDevice+ into Ractor
# shareability for every consumer of +active_support/logger+.
class ::Logger
  class LogDevice
    unless method_defined?(:_ractor_safe_freeze)
      alias_method :_ractor_safe_freeze, :freeze
      def freeze
        unsynchronize! if respond_to?(:unsynchronize!) && !frozen?
        _ractor_safe_freeze
      end
    end
  end
end

module ActiveSupport
  class Logger < ::Logger
    include LoggerSilence

    # Returns true if the logger destination matches one of the sources
    #
    #   logger = Logger.new(STDOUT)
    #   ActiveSupport::Logger.logger_outputs_to?(logger, STDOUT)
    #   # => true
    #
    #   logger = Logger.new('/var/log/rails.log')
    #   ActiveSupport::Logger.logger_outputs_to?(logger, '/var/log/rails.log')
    #   # => true
    def self.logger_outputs_to?(logger, *sources)
      loggers = if logger.is_a?(BroadcastLogger)
        logger.broadcasts
      else
        [logger]
      end

      logdevs = loggers.map { |logger| logger.instance_variable_get(:@logdev) }
      logger_sources = logdevs.filter_map { |logdev| logdev.try(:filename) || logdev.try(:dev) }

      normalize_sources(sources).intersect?(normalize_sources(logger_sources))
    end

    def initialize(*args, **kwargs)
      super
      @formatter ||= SimpleFormatter.new
    end

    # Simple formatter which only displays the message.
    class SimpleFormatter < ::Logger::Formatter
      # This method is invoked when a log event occurs
      def call(severity, timestamp, progname, msg)
        "#{String === msg ? msg : msg.inspect}\n"
      end
    end

    private
      def self.normalize_sources(sources)
        sources.map do |source|
          source = source.path if source.respond_to?(:path)
          source = File.realpath(source) if source.is_a?(String) && File.exist?(source)
          source
        end
      end
  end
end
