# frozen_string_literal: true

require "active_support/logger"

module ActiveSupport
  module Logging # :nodoc:
    class Actor # :nodoc:
      def self.spawn(...)
        new.spawn(...)
      end

      def initialize
        unless defined?(::Ractor::Port)
          raise NotImplementedError, "ActiveSupport::Logging::Actor requires Ractor::Port support"
        end

        @port = ::Ractor::Port.new
      end

      def spawn(logdev = nil, shift_age = 0, shift_size = 1048576, binmode: false, shift_period_suffix: "%Y%m%d", inflight: nil)
        device = build_logdev(logdev, shift_age, shift_size, binmode, shift_period_suffix)
        start_consumer(@port, device, inflight)
        ::Ractor.make_shareable(self)
      end

      def async(message)
        @port << [:write, message]
      end

      def call(operation, *args)
        reply = reply_port
        @port << [:call, reply, operation, args]
        status, value = reply.receive
        raise RuntimeError, value if status == :error
        value
      end

      def drain
        call(:drain)
      end

      def shutdown
        call(:shutdown) unless @port.closed?
      ensure
        @port.close
      end

      private
        # Reuse one reply port per calling thread instead of allocating one per call. A thread blocks on its own reply,
        # so its calls are serial and the port is safe to reuse.
        def reply_port
          ::Thread.current.thread_variable_get(:active_support_logging_reply_port) ||
            ::Thread.current.thread_variable_set(:active_support_logging_reply_port, ::Ractor::Port.new)
        end

        def build_logdev(logdev, shift_age, shift_size, binmode, shift_period_suffix)
          return NullDevice.new if logdev.nil?

          ::Logger::LogDevice.new(logdev,
            shift_age: shift_age,
            shift_size: shift_size,
            shift_period_suffix: shift_period_suffix,
            binmode: binmode)
        end

        def start_consumer(port, logdev, inflight)
          Thread.new do
            closed = false
            loop do
              message = port.receive
              case message[0]
              when :write
                begin
                  logdev.write(message[1])
                ensure
                  # Always decrement, even on write failure, so producers don't
                  # get stuck above the threshold.
                  inflight&.decrement
                end
              when :call
                _, reply, operation, args = message
                case operation
                when :write
                  # Synchronous write requested by a backpressured producer. The producer is already blocked, so this
                  # path leaves the inflight counter untouched.
                  logdev.write(args.first)
                  reply << [:ok, :ok]
                when :drain
                  flush_device(logdev)
                  reply << [:ok, :ok]
                when :shutdown
                  flush_device(logdev)
                  logdev.close
                  closed = true
                  reply << [:ok, true]
                  break
                else
                  reply << [:error, "unknown logger operation: #{operation.inspect}"]
                end
              end
            end
          rescue ::Ractor::ClosedError
            # Port was closed during shutdown.
          rescue StandardError => error
            warn "[ActiveSupport::Logging::Actor] #{error.class}: #{error.message}"
          ensure
            logdev.close unless closed
          end
        end

        # Logger::LogDevice does not expose #flush: flush the underlying IO so +drain+ guarantees buffered output has
        # reached the OS.
        def flush_device(logdev)
          dev = logdev.respond_to?(:dev) ? logdev.dev : logdev
          dev.flush if dev.respond_to?(:flush)
        end

        class NullDevice # :nodoc:
          def write(_message); end
          def close; end
        end
    end
  end
end
