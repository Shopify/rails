# frozen_string_literal: true

module ActiveSupport
  module IsolatedExecutionState # :nodoc:
    @isolation_level = nil

    Thread.attr_accessor :active_support_execution_state
    Fiber.attr_accessor :active_support_execution_state

    class << self
      attr_reader :isolation_level, :scope

      def isolation_level=(level)
        return if level == @isolation_level

        unless %i(thread fiber fiber_storage).include?(level)
          raise ArgumentError, "isolation_level must be `:thread`, `:fiber`, or `:fiber_storage`, got: `#{level.inspect}`"
        end

        # Should we raise if fiber storage is not supported on the Ruby version?

        clear if @isolation_level

        @scope =
          case level
          when :thread; Thread
          when :fiber, :fiber_storage; Fiber
          end

        @isolation_level = level
      end

      def unique_id
        self[:__id__] ||= Object.new
      end

      def [](key)
        state[key]
      end

      def []=(key, value)
        state[key] = value
      end

      def key?(key)
        state.key?(key)
      end

      def delete(key)
        state.delete(key)
      end

      def clear
        state.clear
      end

      def context
        scope.current
      end

      def share_with(other)
        # Action Controller streaming spawns a new thread and copy thread locals.
        # We do the same here for backward compatibility, but this is very much a hack
        # and streaming should be rethought.
        context.active_support_execution_state = other.active_support_execution_state.dup
      end

      private
        def state
          case isolation_level
          when :fiber_storage
            scope[:active_support_execution_state] ||= {}
          else
            context.active_support_execution_state ||= {}
          end
        end
      end

    self.isolation_level = :thread
  end
end
