# frozen_string_literal: true

require "concurrent/map"

module ActiveSupport
  module ConcurrentMapFreezable # :nodoc:
    class NullLock # :nodoc:
      def synchronize
        yield
      end
    end

    NULL_LOCK = NullLock.new.freeze

    def freeze
      instance_variable_get(:@backend)&.freeze if instance_variable_defined?(:@backend)
      instance_variable_set(:@write_lock, NULL_LOCK) if instance_variable_defined?(:@write_lock)
      instance_variable_set(:@mutex, NULL_LOCK) if instance_variable_defined?(:@mutex)
      Object.instance_method(:freeze).bind_call(self)
    end
  end
end

Concurrent::Map.prepend(ActiveSupport::ConcurrentMapFreezable)
