# frozen_string_literal: true

require "active_support/shareable_logger/writer"

module ActiveSupport
  class ShareableLogger
    class DeviceProxy # :nodoc:
      # +sync_threshold+: when set to a positive Integer, producers switch from async to a synchronous, blocking write
      # once the writer's in-flight count reaches it, bounding queue depth at the cost of producer latency. +nil+ (the
      # default) is purely async.
      def initialize(*args, sync_threshold: nil, **logdev_options)
        validate_sync_threshold(sync_threshold)
        @sync_threshold = sync_threshold
        @inflight =
          if @sync_threshold
            require_ractor_safe!
            ::RactorSafe::AtomicInteger.new(0)
          end
        @writer = Writer.spawn(*args, inflight: @inflight, **logdev_options)
        @closed = false
      end

      # The threshold check is a soft limit: multiple producers may observe
      # +threshold - 1+ and briefly exceed it.
      def write(message)
        return if @closed

        if @sync_threshold && @inflight.value >= @sync_threshold
          @writer.call(:write, message)
        else
          @inflight&.increment
          @writer.async(message)
        end
        message.bytesize
      end

      def flush
        @writer.flush unless @closed
        true
      end

      def close
        return true if @closed

        @writer.shutdown
        @closed = true unless frozen?
        true
      end

      def reopen(log = nil, **options)
        @writer.reopen(log, options) unless @closed
        self
      end

      private
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
    end
  end
end
