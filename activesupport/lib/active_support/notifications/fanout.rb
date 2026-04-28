# frozen_string_literal: true

require "concurrent/map"
require "active_support/core_ext/object/try"

module ActiveSupport
  module Notifications
    class InstrumentationSubscriberError < RuntimeError
      attr_reader :exceptions

      def initialize(exceptions)
        @exceptions = exceptions
        exception_class_names = exceptions.map { |e| e.class.name }
        super "Exception(s) occurred within instrumentation subscribers: #{exception_class_names.join(', ')}"
      end
    end

    module FanoutIteration # :nodoc:
      private
        def iterate_guarding_exceptions(collection, &block)
          case collection.size
          when 0
          when 1
            collection.each(&block)
          else
            exceptions = nil

            collection.each do |s|
              yield s
            rescue Exception => e
              exceptions ||= []
              exceptions << e
            end

            if exceptions
              exceptions = exceptions.flat_map do |exception|
                exception.is_a?(InstrumentationSubscriberError) ? exception.exceptions : [exception]
              end
              if exceptions.size == 1
                raise exceptions.first
              else
                raise InstrumentationSubscriberError.new(exceptions), cause: exceptions.first
              end
            end
          end

          collection
        end
    end

    # This is a default queue implementation that ships with Notifications.
    # It just pushes events to all registered log subscribers.
    #
    # This class is thread safe. All methods are reentrant.
    class Fanout
      def initialize
        @mutex = Mutex.new
        @string_subscribers = Concurrent::Map.new { |h, k| h.compute_if_absent(k) { [] } }
        @other_subscribers = []
        @all_listeners_for = Concurrent::Map.new
        @groups_for = Concurrent::Map.new
      end

      def inspect # :nodoc:
        total_patterns = @string_subscribers.size + @other_subscribers.size
        "#<#{self.class} (#{total_patterns} patterns)>"
      end

      # Prepare the notifier for cross-Ractor reads of
      # +ActiveSupport::Notifications.@notifier+ (and the analogous read in
      # +Notifications.instrumenter+).
      #
      # Subscribers are registered at boot via +Notifications.subscribe+ and
      # +ActiveSupport::Subscriber.attach_to+ (LogSubscribers, etc.). In a
      # production app, by the time +Rails.application.ractorize!+ runs, no
      # further subscribe/unsubscribe traffic happens, so the synchronization
      # mutex and cache-on-miss writes are dead.
      #
      # +Concurrent::Map+ does not implement +#freeze+, so we snapshot
      # +@string_subscribers+, +@all_listeners_for+, and +@groups_for+ into
      # frozen plain Hashes. +@string_subscribers+'s default-proc returned
      # +[]+ on miss; we replicate that with +Hash.new([].freeze)+ so existing
      # call sites that do +@string_subscribers[name] + ...+ keep working.
      #
      # The mutex is dropped to +nil+; +all_listeners_for+ and +groups_for+
      # branch on +@mutex+ to skip cache writes when it's gone.
      def make_shareable! # :nodoc:
        return self if frozen?

        @mutex = nil

        string_subscribers = Hash.new([].freeze)
        @string_subscribers.each_pair { |k, v| string_subscribers[k] = v.freeze }
        @string_subscribers = string_subscribers.freeze

        @other_subscribers.freeze

        all_listeners_for = {}
        @all_listeners_for.each_pair { |k, v| all_listeners_for[k] = v.freeze }
        @all_listeners_for = all_listeners_for.freeze

        groups_for = {}
        @groups_for.each_pair { |k, v| groups_for[k] = v.freeze }
        @groups_for = groups_for.freeze

        super
      end

      def subscribe(pattern = nil, callable = nil, monotonic: false, prepend: false, &block)
        if @mutex.nil?
          raise FrozenError,
            "ActiveSupport::Notifications::Fanout has been frozen for Ractor " \
            "safety; subscribers must be attached during boot, before " \
            "Rails.application.ractorize!. (e.g. via Rails::Application.config " \
            "initializers, ActiveSupport::LogSubscriber.attach_to, or " \
            "ActiveSupport.on_load load hooks.)"
        end
        subscriber = Subscribers.new(pattern, callable || block, monotonic)
        @mutex.synchronize do
          case pattern
          when String
            if prepend
              @string_subscribers[pattern].unshift(subscriber)
            else
              @string_subscribers[pattern] << subscriber
            end
            clear_cache(pattern)
          when NilClass, Regexp
            if prepend
              raise ArgumentError, "Cannot prepend Regex subscribers"
            end
            @other_subscribers << subscriber
            clear_cache
          else
            raise ArgumentError,  "pattern must be specified as a String, Regexp or empty"
          end
        end
        subscriber
      end

      def unsubscribe(subscriber_or_name)
        if @mutex.nil?
          raise FrozenError,
            "ActiveSupport::Notifications::Fanout has been frozen for Ractor " \
            "safety; subscribers must be attached during boot, before " \
            "Rails.application.ractorize!. (e.g. via Rails::Application.config " \
            "initializers, ActiveSupport::LogSubscriber.attach_to, or " \
            "ActiveSupport.on_load load hooks.)"
        end
        @mutex.synchronize do
          case subscriber_or_name
          when String
            @string_subscribers[subscriber_or_name].clear
            clear_cache(subscriber_or_name)
            @other_subscribers.each { |sub| sub.unsubscribe!(subscriber_or_name) }
          else
            pattern = subscriber_or_name.try(:pattern)
            if String === pattern
              @string_subscribers[pattern].delete(subscriber_or_name)
              clear_cache(pattern)
            else
              @other_subscribers.delete(subscriber_or_name)
              clear_cache
            end
          end
        end
      end

      def clear_cache(key = nil) # :nodoc:
        if key
          @all_listeners_for.delete(key)
          @groups_for.delete(key)
        else
          @all_listeners_for.clear
          @groups_for.clear
        end
      end

      class BaseGroup # :nodoc:
        include FanoutIteration

        def initialize(listeners, name, id, payload)
          @listeners = listeners
        end

        def each(&block)
          iterate_guarding_exceptions(@listeners, &block)
        end
      end

      class BaseTimeGroup < BaseGroup # :nodoc:
        def start(name, id, payload)
          @start_time = now
        end

        def finish(name, id, payload)
          stop_time = now
          each do |listener|
            listener.call(name, @start_time, stop_time, id, payload)
          end
        end
      end

      class MonotonicTimedGroup < BaseTimeGroup # :nodoc:
        private
          def now
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end
      end

      class TimedGroup < BaseTimeGroup # :nodoc:
        private
          def now
            Time.now
          end
      end

      class EventedGroup < BaseGroup # :nodoc:
        def start(name, id, payload)
          each do |s|
            s.start(name, id, payload)
          end
        end

        def finish(name, id, payload)
          each do |s|
            s.finish(name, id, payload)
          end
        end
      end

      class EventObjectGroup < BaseGroup # :nodoc:
        def start(name, id, payload)
          @event = build_event(name, id, payload)
          @event.start!
        end

        def finish(name, id, payload)
          @event.payload = payload
          @event.finish!

          each do |s|
            s.call(@event)
          end
        end

        private
          def build_event(name, id, payload)
            ActiveSupport::Notifications::Event.new name, nil, nil, id, payload
          end
      end

      def group_listeners(listeners) # :nodoc:
        listeners.group_by(&:group_class).transform_values do |s|
          s.map(&:delegate).freeze
        end.freeze
      end

      def groups_for(name) # :nodoc:
        cached = @groups_for[name]
        if cached
          silenceable_groups, groups = cached
        else
          listeners = all_listeners_for(name)
          silenceable_groups, groups = listeners.partition(&:silenceable).map { |l| group_listeners(l) }

          if @mutex
            @mutex.synchronize do
              @groups_for[name] ||= [silenceable_groups, groups]
            end
          end
          # When @mutex is nil (post-+make_shareable!+), we skip the cache write
          # because @groups_for is frozen; recompute on every miss.
        end

        unless silenceable_groups.empty?
          silenceable_groups.each do |group_class, subscriptions|
            active_subscriptions = subscriptions.reject { |s| s.silenced?(name) }
            unless active_subscriptions.empty?
              groups = groups.dup if groups.frozen?
              base_groups = groups[group_class]
              groups[group_class] = base_groups ? base_groups + active_subscriptions : active_subscriptions
            end
          end
        end

        groups
      end

      # A +Handle+ is used to record the start and finish time of event.
      #
      # Both #start and #finish must each be called exactly once.
      #
      # Where possible, it's best to use the block form: ActiveSupport::Notifications.instrument.
      # +Handle+ is a low-level API intended for cases where the block form can't be used.
      #
      #   handle = ActiveSupport::Notifications.instrumenter.build_handle("my.event", {})
      #   begin
      #     handle.start
      #     # work to be instrumented
      #   ensure
      #     handle.finish
      #   end
      class Handle
        include FanoutIteration

        def initialize(notifier, name, id, groups, payload) # :nodoc:
          @name = name
          @id = id
          @payload = payload
          @groups = groups
          @state = :initialized
        end

        def start
          ensure_state! :initialized
          @state = :started

          iterate_guarding_exceptions(@groups) do |group|
            group.start(@name, @id, @payload)
          end
        end

        def finish
          finish_with_values(@name, @id, @payload)
        end

        def finish_with_values(name, id, payload) # :nodoc:
          ensure_state! :started
          @state = :finished

          iterate_guarding_exceptions(@groups) do |group|
            group.finish(name, id, payload)
          end
        end

        private
          def ensure_state!(expected)
            if @state != expected
              raise ArgumentError, "expected state to be #{expected.inspect} but was #{@state.inspect}"
            end
          end
      end

      module NullHandle # :nodoc:
        extend self

        def start
        end

        def finish
        end

        def finish_with_values(_name, _id, _payload)
        end
      end

      include FanoutIteration

      def build_handle(name, id, payload)
        groups = groups_for(name).map do |group_klass, grouped_listeners|
          group_klass.new(grouped_listeners, name, id, payload)
        end

        if groups.empty?
          NullHandle
        else
          Handle.new(self, name, id, groups, payload)
        end
      end

      def start(name, id, payload)
        handle_stack = (IsolatedExecutionState[:_fanout_handle_stack] ||= [])
        handle = build_handle(name, id, payload)
        handle_stack << handle
        handle.start
      end

      def finish(name, id, payload, listeners = nil)
        handle_stack = IsolatedExecutionState[:_fanout_handle_stack]
        handle = handle_stack.pop
        handle.finish_with_values(name, id, payload)
      end

      def publish(name, ...)
        iterate_guarding_exceptions(listeners_for(name)) { |s| s.publish(name, ...) }
      end

      def publish_event(event)
        iterate_guarding_exceptions(listeners_for(event.name)) { |s| s.publish_event(event) }
      end

      def all_listeners_for(name)
        # this is correctly done double-checked locking (Concurrent::Map's lookups have volatile semantics)
        cached = @all_listeners_for[name]
        return cached if cached

        listeners = @string_subscribers[name] + @other_subscribers.select { |s| s.subscribed_to?(name) }

        if @mutex
          # use synchronisation when accessing @subscribers
          @mutex.synchronize do
            @all_listeners_for[name] ||= listeners
          end
        else
          # Post-+make_shareable!+ (e.g. inside +Rails.application.ractorize!+),
          # the cache hash and subscriber lists are frozen and no further
          # subscribe/unsubscribe traffic happens, so we just return the freshly
          # computed list without writing it back into the cache.
          listeners
        end
      end

      def listeners_for(name)
        all_listeners_for(name).reject { |s| s.silenced?(name) }
      end

      def listening?(name)
        all_listeners_for(name).any? { |s| !s.silenced?(name) }
      end

      # This is a sync queue, so there is no waiting.
      def wait
      end

      module Subscribers # :nodoc:
        def self.new(pattern, listener, monotonic)
          subscriber_class = monotonic ? MonotonicTimed : Timed

          if listener.respond_to?(:start) && listener.respond_to?(:finish)
            subscriber_class = Evented
          else
            # Doing this to detect a single argument block or callable
            # like `proc { |x| }` vs `proc { |*x| }`, `proc { |**x| }`,
            # or `proc { |x, **y| }`
            procish = listener.respond_to?(:parameters) ? listener : listener.method(:call)

            if procish.arity == 1 && procish.parameters.length == 1
              subscriber_class = EventObject
            end
          end

          subscriber_class.new(pattern, listener)
        end

        class Matcher # :nodoc:
          attr_reader :pattern, :exclusions

          def self.wrap(pattern)
            if String === pattern
              pattern
            elsif pattern.nil?
              AllMessages.new
            else
              new(pattern)
            end
          end

          def initialize(pattern)
            @pattern = pattern
            @exclusions = Set.new
          end

          def unsubscribe!(name)
            exclusions << -name if pattern === name
          end

          def ===(name)
            pattern === name && !exclusions.include?(name)
          end

          class AllMessages
            def ===(name)
              true
            end

            def unsubscribe!(*)
              false
            end
          end
        end

        class Evented # :nodoc:
          attr_reader :pattern, :delegate, :silenceable

          def initialize(pattern, delegate)
            @pattern = Matcher.wrap(pattern)
            @delegate = delegate
            @silenceable = delegate.respond_to?(:silenced?)
            @can_publish = delegate.respond_to?(:publish)
            @can_publish_event = delegate.respond_to?(:publish_event)
          end

          def group_class
            EventedGroup
          end

          def publish(...)
            if @can_publish
              @delegate.publish(...)
            end
          end

          def publish_event(event)
            if @can_publish_event
              @delegate.publish_event event
            else
              publish(event.name, event.time, event.end, event.transaction_id, event.payload)
            end
          end

          def silenced?(name)
            @silenceable && @delegate.silenced?(name)
          end

          def subscribed_to?(name)
            pattern === name
          end

          def unsubscribe!(name)
            pattern.unsubscribe!(name)
          end
        end

        class Timed < Evented # :nodoc:
          def group_class
            TimedGroup
          end

          def publish(...)
            @delegate.call(...)
          end
        end

        class MonotonicTimed < Timed # :nodoc:
          def group_class
            MonotonicTimedGroup
          end
        end

        class EventObject < Evented
          def group_class
            EventObjectGroup
          end

          def publish_event(event)
            @delegate.call event
          end
        end
      end
    end
  end
end
