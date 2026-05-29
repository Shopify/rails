# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    # Shareable substitute returned by ActiveRecord::Base.connection_handler when
    # the reader is invoked from a non-main Ractor.
    #
    # The real ConnectionHandler holds a Concurrent::Map of pool managers, each
    # of which owns ConnectionPool instances backed by Mutex/ConditionVariable
    # and live driver state. None of that is shareable, so non-main Ractors
    # cannot reach the real handler.
    #
    # Reading the class_attribute :default_connection_handler ivar from a non-main
    # Ractor would raise Ractor::IsolationError on the unshareable handler value.
    # Returning this shareable stub from the +connection_handler+ reader avoids
    # the ivar read entirely on the non-main path.
    #
    # The surface here is intentionally minimal: only the methods invoked on the
    # handler from non-main Ractors during request execution (executor hooks,
    # transaction tracking) are defined. Methods that mutate or check live pool
    # state return safe no-op values. New requirements should be added one by
    # one as request-path callers reveal them, rather than mirroring the full
    # ConnectionHandler API up front.
    module RactorConnectionHandler
      extend self

      EMPTY_POOLS = [].freeze

      # Used by ActiveRecord::QueryCache::ExecutorHooks.run and
      # ActiveRecord.all_open_transactions on every executor wrap. Returns an
      # empty enumerator so the iteration yields nothing in non-main Ractors.
      def each_connection_pool(role = nil)
        return enum_for(:each_connection_pool, role) unless block_given?
        # No pools visible from a non-main Ractor; nothing to yield.
      end

      def connection_pool_list(role = nil)
        EMPTY_POOLS
      end
      alias :connection_pools :connection_pool_list

      def active_connections?(role = nil)
        false
      end

      def connected?(connection_name, role: nil, shard: nil)
        false
      end

      # Anything else called on this stub from a non-main Ractor is a request-
      # path code path we haven't audited yet. Fail loudly with a message that
      # names the stub, the missing method, and this file so the next debugger
      # can either extend the surface here or route the caller through the
      # real handler on the main Ractor.
      def method_missing(name, *, **, &)
        raise NoMethodError,
          "#{name} is not implemented on #{self} (the non-main-Ractor stub " \
          "for ActiveRecord::ConnectionAdapters::ConnectionHandler). The " \
          "request-path read surface is intentionally limited; if you hit " \
          "this, extend the stub at #{__FILE__} or route the caller through " \
          "the real handler on the main Ractor."
      end

      def respond_to_missing?(name, include_private = false)
        false
      end
    end

    Ractor.make_shareable(RactorConnectionHandler)
  end
end
