# frozen_string_literal: true

require "logger"
require "stringio"

module ActiveSupport
  module Ractors # :nodoc:
    # A Ractor-safe log device.
    #
    # The standard ::Logger::LogDevice guards its IO with a Monitor, which can be
    # frozen neither by Ractor.make_shareable nor written to from a non-main
    # Ractor. Instead, log lines are handed to a dedicated consumer thread over a
    # Ractor::Port, so the object stored in the (frozen, shared) logger holds no
    # Monitor or IO -- only a shareable Writer handle.
    class Logger
      class Writer # :nodoc:
        def self.spawn(...)
          new.spawn(...)
        end

        def initialize
          unless defined?(::Ractor::Port)
            raise NotImplementedError, "ActiveSupport::Ractors::Logger requires Ractor::Port support"
          end
          @port = ::Ractor::Port.new
        end

        def spawn(logdev = nil, shift_age = 0, shift_size = 1048576, binmode: false, shift_period_suffix: "%Y%m%d")
          device = build_logdev(logdev, shift_age, shift_size, binmode, shift_period_suffix)
          start_consumer(@port, device)
          ::Ractor.make_shareable(self)
        end

        def async(message)
          @port << [:write, message]
        rescue ::Ractor::ClosedError
          nil
        end

        def call(operation, *args)
          reply = reply_port
          @port << [:call, reply, operation, args]
          status, value = reply.receive
          raise RuntimeError, value if status == :error
          value
        rescue ::Ractor::ClosedError
          nil
        end

        def flush = call(:flush)
        def reopen(log, options) = call(:reopen, log, options)

        def shutdown
          call(:shutdown) unless @port.closed?
        ensure
          @port.close
        end

        private
          def reply_port
            ::Thread.current.thread_variable_get(:active_support_shareable_logger_reply_port) ||
              ::Thread.current.thread_variable_set(:active_support_shareable_logger_reply_port, ::Ractor::Port.new)
          end

          def build_logdev(logdev, shift_age, shift_size, binmode, shift_period_suffix)
            return NullDevice.new if logdev.nil?

            ::Logger::LogDevice.new(logdev,
              shift_age: shift_age, shift_size: shift_size,
              shift_period_suffix: shift_period_suffix, binmode: binmode)
          end

          def start_consumer(port, logdev)
            Thread.new do
              closed = false
              until closed
                begin
                  message = port.receive
                rescue ::Ractor::ClosedError
                  break
                end
                case message[0]
                when :write
                  begin
                    logdev.write(message[1])
                  rescue StandardError => error
                    warn_failure(error)
                  end
                when :call
                  _, reply, operation, args = message
                  begin
                    case operation
                    when :flush    then flush_device(logdev)
                    when :reopen   then logdev.reopen(args[0], **args[1])
                    when :shutdown then flush_device(logdev); logdev.close; closed = true
                    end
                  rescue StandardError => error
                    warn_failure(error)
                  ensure
                    reply << [:ok, operation == :shutdown ? true : :ok]
                  end
                end
              end
            ensure
              unless closed
                logdev.close
                port.close
              end
            end
          end

          def warn_failure(error)
            warn "[ActiveSupport::Ractors::Logger::Writer] #{error.class}: #{error.message}"
          end

          def flush_device(logdev)
            dev = logdev.respond_to?(:dev) ? logdev.dev : logdev
            dev.flush if dev.respond_to?(:flush)
          end

          class NullDevice # :nodoc:
            def write(_message); end
            def reopen(*); end
            def close; end
          end
      end

      class DeviceProxy # :nodoc:
        def initialize(*args, **logdev_options)
          @writer = Writer.spawn(*args, **logdev_options)
          @closed = false
        end

        def write(message)
          return if @closed
          @writer.async(message)
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
      end

      # Prepended to ActiveSupport::Logger: on freeze, swap the Monitor-backed
      # LogDevice for a Ractor-safe DeviceProxy pointing at the same file/IO.
      module ShareableDevice
        def freeze
          logdev = @logdev
          if logdev.is_a?(::Logger::LogDevice) && !Ractor.shareable?(logdev)
            target = logdev.filename || logdev.dev
            @logdev = DeviceProxy.new(target)
          end
          super
        end
      end
    end
  end
end
