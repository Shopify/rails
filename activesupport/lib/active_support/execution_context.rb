# frozen_string_literal: true

module ActiveSupport
  module ExecutionContext # :nodoc:
    @after_change_callbacks = []
    class << self
      def after_change(&block)
        @after_change_callbacks << block
      end

      # Updates the execution context. If a block is given, it resets the provided keys to their
      # previous value once the block exits.
      def set(copy: false, **options)
        options.symbolize_keys!
        keys = options.keys

        store = self.store

        previous_context = keys.zip(store.values_at(*keys)).to_h

        if copy
          dup_execution_state[:active_support_execution_context] = store.merge(options)
        else
          store.merge!(options)
        end
        @after_change_callbacks.each(&:call)

        if block_given?
          begin
            yield
          ensure
            self.store.merge!(previous_context)
            @after_change_callbacks.each(&:call)
          end
        end
      end

      def []=(key, value)
        store[key.to_sym] = value
        @after_change_callbacks.each(&:call)
      end

      def to_h
        store.dup
      end

      def clear
        store.clear
      end

      private
        def dup_execution_state
          IsolatedExecutionState.dup
        end

        def store
          IsolatedExecutionState[:active_support_execution_context] ||= {}
        end
    end
  end
end
