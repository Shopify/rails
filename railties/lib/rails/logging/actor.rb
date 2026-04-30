# frozen_string_literal: true

module Rails
  module Logging
    # = Logger Actor
    #
    # A single consumer Thread that owns the real log device. Producer
    # Ractors send log messages through a +Ractor::Port+; the consumer
    # drains the port and writes to the device.
    #
    # The actor instance is itself made Ractor-shareable so that
    # +Rails::Logging::Proxy+ (held by every Ractor as +Rails.logger+) can reach
    # it. To stay shareable, the actor only holds the port as state —
    # the mutable log device lives only in the consumer Thread's
    # closure, never as an ivar of +self+. This mirrors the pattern in
    # +Ractor::Dispatch::Executor+.
    #
    # ==== Backpressure (v1)
    #
    # The mailbox is unbounded. Writes never block producer Ractors.
    # If the consumer falls behind, the port queue grows. A future
    # version may add severity-based throttling (e.g. errors go
    # through +call+ instead of +cast+) or a side-channel depth
    # counter. See +plans/logger-actor.md+.
    #
    # ==== Crash recovery
    #
    # If the consumer Thread dies, queued messages pile up. v1 does
    # not restart the consumer.
    class Actor
      def initialize(real_logger)
        @port = ::Ractor::Port.new

        # Build a fresh logger over a freshly-opened IO. This sidesteps
        # the fact that the original Rails.logger's IO (typically
        # STDOUT) gets frozen elsewhere during ractorize!, which would
        # then make the consumer thread fail on every `add`. The fresh
        # IO is held only by the consumer-thread closure — never as an
        # ivar of self, so it isn't reachable through the shareable
        # graph.
        consumer_logger = build_consumer_logger(real_logger)

        # LOGGER_SLOW_MS=N injects an N-millisecond sleep before every
        # write in the consumer. Used by scripts/logger_demo.rb to
        # demonstrate the head-of-line blocking limit of a single
        # consumer thread. Zero means no overhead.
        slow_ms = (ENV["LOGGER_SLOW_MS"] || "0").to_f

        spawn_consumer(consumer_logger, @port, slow_ms)

        ::Ractor.make_shareable(self)
      end

      # Fire-and-forget log write. Always non-blocking from the caller's
      # perspective.
      def cast(severity, message, tags)
        @port << [:write, severity, message, tags]
      end

      # Synchronous request: send a message and wait for a reply on a
      # one-shot reply port. Used for +flush+ and any other operation
      # that needs to observe consumer state.
      def call(op, *args)
        reply = ::Ractor::Port.new
        @port << [:call, reply, op, args]
        status, val = reply.receive
        reply.close
        raise val if status == :error
        val
      end

      def flush
        call(:flush)
      end

      def shutdown
        flush
        @port << [:stop]
        sleep(0.01)
      end

      private
        # Construct a fresh ActiveSupport::Logger pointed at the same
        # destination as +source+, but with a brand-new IO that won't
        # be frozen by the rest of ractorize! traversal.
        def build_consumer_logger(source)
          require "active_support/logger"
          require "active_support/tagged_logging"

          inner = source.respond_to?(:broadcasts) ? source.broadcasts.first : source
          logdev = inner.instance_variable_get(:@logdev)
          path = logdev&.filename
          fd = (logdev&.dev&.fileno rescue nil)

          io =
            if path
              File.open(path, "a")
            elsif fd
              ::IO.new(::IO.sysopen("/dev/fd/#{fd}", "w"), "w")
            else
              $stderr
            end
          io.sync = true

          fresh = ::ActiveSupport::Logger.new(io)
          fresh.level     = inner.level
          fresh.progname  = inner.progname || "Rails"
          fresh.formatter = inner.formatter.class.new if inner.formatter
          ::ActiveSupport::TaggedLogging.new(fresh)
        end

        def spawn_consumer(logger, port, slow_ms)
          delay = slow_ms / 1000.0
          Thread.new do
            begin
              loop do
                msg = port.receive
                case msg[0]
                when :write
                  _, severity, message, tags = msg
                  write_one(logger, severity, message, tags, delay)
                when :call
                  _, reply, op, args = msg
                  handle_call(logger, reply, op, args, delay)
                when :stop
                  break
                end
              end
            rescue ::Ractor::ClosedError
              # Port was closed; exit quietly.
            rescue => e
              warn "[Rails::Logging::Actor] consumer error: #{e.class}: #{e.message}"
            end
          end
        end

        def write_one(logger, severity, message, tags, delay)
          sleep(delay) if delay > 0
          if tags && !tags.empty? && logger.respond_to?(:tagged)
            logger.tagged(*tags) { logger.add(severity, message) }
          else
            logger.add(severity, message)
          end
        rescue => e
          warn "[Rails::Logging::Actor] write error: #{e.class}: #{e.message}"
        end

        def handle_call(logger, reply, op, args, delay)
          result =
            case op
            when :flush
              logger.flush if logger.respond_to?(:flush)
              :ok
            when :level
              logger.level
            when :write
              severity, message, tags = args
              write_one(logger, severity, message, tags, delay)
              :ok
            else
              raise ArgumentError, "unknown op: #{op.inspect}"
            end
          reply << [:ok, result]
        rescue => e
          reply << [:error, e]
        end
    end
  end
end
