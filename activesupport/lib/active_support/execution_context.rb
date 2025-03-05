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
      def set(**options)
        options.symbolize_keys!
        keys = options.keys

        store = self.store

        previous_context = keys.zip(store.values_at(*keys)).to_h

        current_store = store.merge(options)
        IsolatedExecutionState[:active_support_execution_context] = current_store

        if block_given?
          begin
            yield
          ensure
            current_store = self.store.merge(previous_context)
            IsolatedExecutionState[:active_support_execution_context] = current_store

            @after_change_callbacks.each(&:call)
          end
        end
      end

      def []=(key, value)
        current_store = store.merge(key.to_sym => value)
        IsolatedExecutionState[:active_support_execution_context] = current_store
        @after_change_callbacks.each(&:call)
      end

      def to_h
        store.dup
      end

      def clear
        store.clear
      end

      private
        def store
          IsolatedExecutionState[:active_support_execution_context] ||= {}
        end
    end
  end
end
