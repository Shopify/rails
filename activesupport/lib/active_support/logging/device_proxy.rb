# frozen_string_literal: true

require "active_support/logging/actor"

module ActiveSupport
  module Logging # :nodoc:
    class DeviceProxy # :nodoc:
      def initialize(*args, **logdev_options)
        @actor = Actor.spawn(*args, **logdev_options)
        @closed = false
      end

      # Logger::LogDevice#write contract: returns the number of bytes written.
      def write(message)
        return if @closed

        @actor.async(message)
        message.bytesize
      end

      def flush
        @actor.flush unless @closed
        true
      end

      def close
        return true if @closed

        @actor.shutdown
        @closed = true unless frozen?
        true
      end

      def reopen(log = nil, **options)
        @actor.reopen(log, options) unless @closed
        self
      end
    end
  end
end
