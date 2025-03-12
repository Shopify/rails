# frozen_string_literal: true

module ActiveSupport
  module IsolatedExecutionState # :nodoc:
    @isolation_level = nil
    @storage = :accessor

    Thread.attr_accessor :active_support_execution_state
    Fiber.attr_accessor :active_support_execution_state

    class << self
      attr_reader :isolation_level, :scope, :storage

      def isolation_level=(level)
        return if level == @isolation_level

        unless %i(thread fiber).include?(level)
          raise ArgumentError, "isolation_level must be `:thread` or `:fiber`, got: `#{level.inspect}`"
        end

        clear if @isolation_level

        @scope =
          case level
          when :thread; Thread
          when :fiber; Fiber
          end

        @isolation_level = level
      end

      def storage=(mechanism)
        return if mechanism == @storage

        unless %i(accessor fiber_storage).include?(mechanism)
          raise ArgumentError, "storage must be `:accessor` or `:fiber_storage`, got: `#{mechanism.inspect}`"
        end

        clear if @storage

        @storage = mechanism
      end

      def unique_id
        self[:__id__] ||= Object.new
      end

      def [](key)
        state[key]
      end

      def []=(key, value)
        if storage == :fiber_storage
          new_state = state.dup
          new_state[key] = value
          Fiber[:active_support_execution_state] = new_state
        else
          state[key] = value
        end
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
          case storage
          when :fiber_storage
            Fiber[:active_support_execution_state] ||= {}
          else # :accessor
            context.active_support_execution_state ||= {}
          end
        end
    end

    self.isolation_level = :thread
    self.storage = :accessor
  end
end
