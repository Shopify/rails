# frozen_string_literal: true

require "logger"
require "active_support/isolated_execution_state"

module Rails
  module Logging
    # = Logger Proxy
    #
    # Shareable Logger-shaped facade. Every Ractor (including non-main)
    # holds this as its +Rails.logger+. Severity calls are translated
    # into messages and dispatched to a +Rails::Logging::Actor+ which owns the
    # real device.
    #
    # Tagged-logging tags live in +ActiveSupport::IsolatedExecutionState+
    # (per-Fiber/Thread, replicated automatically across Ractors), not on
    # the proxy or the actor. Each outgoing message captures the
    # caller's current tag stack.
    class Proxy
      SEVERITY_METHODS = %i[debug info warn error fatal unknown].freeze

      attr_reader :level, :progname, :sync_threshold

      # +sync_threshold+: when the actor's inflight counter reaches
      # this value, the proxy switches from cast (async) to call
      # (sync) for new writes. Producers then block, naturally
      # throttling to the consumer's drain rate. Zero (default)
      # disables the check — purely cast-only behaviour.
      def initialize(actor, level:, progname: "Rails", sync_threshold: 0)
        @actor          = actor
        @inflight       = actor.inflight
        @level          = level
        @progname       = progname
        @sync_threshold = sync_threshold.to_i
        # Eager: lazy-init would mutate self after freeze.
        @tag_state_key = "rails_ractor_logger_tags:#{object_id}".freeze
        ::Ractor.make_shareable(self)
      end

      SEVERITY_METHODS.each do |severity|
        sev_num = ::Logger::Severity.const_get(severity.upcase)
        class_eval <<~RUBY, __FILE__, __LINE__ + 1
          def #{severity}?
            @level <= #{sev_num}
          end

          def #{severity}(message = nil, &block)
            return true if @level > #{sev_num}
            payload = block ? block.call : message
            dispatch(#{sev_num}, shareable_message(payload), current_tags)
            true
          end

          def #{severity}!
            # no-op: level is fixed at freeze time
          end
        RUBY
      end

      def add(severity, message = nil, progname = nil, &block)
        return true if severity < @level
        payload = block ? block.call : (message || progname)
        dispatch(severity, shareable_message(payload), current_tags)
        true
      end
      alias_method :log, :add

      def <<(message)
        dispatch(::Logger::UNKNOWN, shareable_message(message), current_tags)
        message
      end

      # No-op. ActiveSupport::LogSubscriber.flush_all! calls this at
      # the end of every request, and a synchronous round-trip to the
      # actor would force every request to wait for the entire backlog
      # to drain — cross-request head-of-line blocking. Original
      # ActiveSupport::Logger#flush is also a no-op for the common
      # cases, so this matches expectations.
      #
      # Use +drain!+ when you actually need to wait for the queue to
      # empty (shutdown, tests, demos).
      def flush
        true
      end

      # Synchronous: block until every log message queued before this
      # call has been written by the consumer. Use for shutdown or
      # measurement, not in the request hot path.
      def drain!
        @actor.flush
      end

      def close
        # No-op on the proxy; lifetime owned by the actor.
      end

      # ── Tagged logging ──────────────────────────────────────────────
      def tagged(*tags, &block)
        pushed = push_tags(*tags).size
        yield self
      ensure
        pop_tags(pushed) if pushed
      end

      def push_tags(*tags)
        tags = tags.flatten.reject { |t| blank_tag?(t) }
        tag_stack.concat(tags)
        tags
      end

      def pop_tags(count = 1)
        tag_stack.pop(count)
      end

      def clear_tags!
        tag_stack.clear
      end

      def current_tags
        tag_stack.empty? ? EMPTY_TAGS : tag_stack.dup.freeze
      end

      # Return self so callers like ActiveJob's
      # +logger_tagged_by_active_job?+ can do +formatter.current_tags+
      # without bouncing through a separate object. The proxy
      # implements the bits of the Formatter interface (current_tags)
      # that callers rely on.
      def formatter
        self
      end

      def formatter=(_)
        # no-op: formatting happens on the actor side
      end

      def silence(_severity = ::Logger::ERROR)
        yield self
      end

      def local_level
        nil
      end

      def local_level=(_)
        # no-op
      end

      def log_at(_level)
        yield self
      end

      def broadcasts
        [self]
      end

      # Rails::Server#log_to_stdout calls this to attach a console
      # logger so dev sees output on STDOUT. The proxy writes
      # asynchronously through the logger actor (which already owns
      # the real device); a second sink would need a parallel actor.
      # No-op for now — the actor's device is whatever was wrapped
      # at ractorize! time.
      def broadcast_to(_other)
        self
      end

      def level=(_)
        # no-op after freeze
      end
      alias_method :sev_threshold=, :level=

      EMPTY_TAGS = [].freeze

      private
        # Pick cast vs. call based on the actor's in-flight depth.
        # Above the threshold, the producer blocks until the actor
        # processes one of its older messages — this is OTP
        # +logger_olp+'s async/sync escalation in ~5 lines.
        def dispatch(severity, message, tags)
          if @sync_threshold > 0 && @inflight.value >= @sync_threshold
            @actor.call(:write, severity, message, tags)
          else
            @inflight.increment
            @actor.cast(severity, message, tags)
          end
        end

        def tag_stack
          ActiveSupport::IsolatedExecutionState[@tag_state_key] ||= []
        end

        def shareable_message(msg)
          s = msg.is_a?(::String) ? msg : msg.to_s
          s.frozen? ? s : s.dup.freeze
        end

        def blank_tag?(t)
          return true if t.nil?
          return t.blank? if t.respond_to?(:blank?)
          t == ""
        end
    end
  end
end
