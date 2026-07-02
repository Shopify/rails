# frozen_string_literal: true

# ActiveSupport Ractor patches, applied by Rails::Application#ractorize!.
#
# Behavioral patches (module prepends) are applied at require time (during
# ractorize!, when all constants are loaded). Freeze/warm actions are registered
# as before_freeze/on_freeze callbacks run around make_shareable.

require "active_support/ractors/logger"

module ActiveSupport
  module Ractors
    module NotificationsFallback # :nodoc:
      # The global @notifier (a Fanout with subscribers and mutexes) isn't
      # shareable. In a non-main Ractor, run instrumented blocks without
      # publishing, and hand out a no-op instrumenter.
      def instrument(name, payload = {}, &block)
        unless Ractor.main?
          begin
            notifier
          rescue Ractor::IsolationError
            # The global notifier isn't reachable here: run the instrumented
            # block once, without publishing. Errors from the block propagate.
            return block ? yield(payload) : nil
          end
        end
        super
      end

      def instrumenter
        unless Ractor.main?
          begin
            notifier
          rescue Ractor::IsolationError
            return ActiveSupport::Notifications::NullInstrumenter.new
          end
        end
        super
      end
    end

    module ErrorReporterFallback # :nodoc:
      # Error reporting dispatches to subscribers and per-execution state that
      # isn't shareable; reporting is a main-Ractor concern.
      def report(error, **kwargs)
        return nil unless Ractor.main?
        super
      end
    end

    module LogSubscriberFallback # :nodoc:
      def logger
        return super if Ractor.main?
        (defined?(Rails) && Rails.respond_to?(:logger)) ? Rails.logger : nil
      end

      def flush_all!
        return super if Ractor.main?
        logger.flush if logger.respond_to?(:flush)
      end
    end
  end
end

ActiveSupport::Notifications.singleton_class.prepend(ActiveSupport::Ractors::NotificationsFallback)
ActiveSupport::ErrorReporter.prepend(ActiveSupport::Ractors::ErrorReporterFallback)
ActiveSupport::LogSubscriber.singleton_class.prepend(ActiveSupport::Ractors::LogSubscriberFallback)
ActiveSupport::Logger.prepend(ActiveSupport::Ractors::Logger::ShareableDevice)

# Convert callback/condition procs to shareable procs during the freeze phase
# (rails/rails#57629) so controller callback chains can be made Ractor-shareable
# and actually run inside a non-main Ractor.
ActiveSupport::Ractors.on_freeze do
  ActiveSupport::Ractors.unshareable_proc_action = :raise
end

# concurrent-ruby's Concurrent::Map#compute_if_absent reads the Concurrent::NULL
# sentinel constant; freeze it so a Ractor-local Concurrent::Map is usable from a
# non-main Ractor.
ActiveSupport::Ractors.on_freeze do
  # ActiveSupport::Digest memoizes @hash_digest_class (a Class); warm it so a
  # non-main Ractor reads it instead of assigning it.
  ActiveSupport::Digest.hash_digest_class if defined?(ActiveSupport::Digest)

  Ractor.make_shareable(Concurrent::NULL) if defined?(Concurrent::NULL)
  Ractor.make_shareable(Concurrent::NO_VALUE) if defined?(Concurrent::NO_VALUE)
end

# Time.zone falls back to Time.zone_default (an ActiveSupport::TimeZone kept in a
# class ivar) when no per-execution zone is set. A non-main Ractor can't read an
# unshareable class ivar, so freeze the default zone (warming its lazy tzinfo
# first) for timezone conversions on the request/write path.
ActiveSupport::Ractors.on_freeze do
  if defined?(Time) && Time.respond_to?(:zone_default) && (zone = Time.zone_default)
    Time.now.in_time_zone(zone) rescue nil # warm lazy tzinfo period caches
    Ractor.make_shareable(zone)
  end
end

# Inflector memoizes the inflections singleton in a class ivar (@__en_instance__)
# read by String#camelize/underscore on the request path.
ActiveSupport::Ractors.on_freeze do
  inflections = ActiveSupport::Inflector::Inflections.instance(:en)
  inflections.uncountables.uncountable?("sheep") # warm the lazy pattern
  ActiveSupport::Ractors.make_shareable(inflections)
end

# LocalCache#local_cache_key memoizes a key onto the (soon-frozen) cache store.
ActiveSupport::Ractors.before_freeze do
  store = Rails.cache if defined?(Rails)
  store.send(:local_cache_key) if store.respond_to?(:local_cache_key, true)
end

# CurrentAttributes (the app's Current model) memoizes class-level state.
ActiveSupport::Ractors.on_freeze do
  (ActiveSupport::CurrentAttributes.descendants + [ActiveSupport::CurrentAttributes]).each do |klass|
    klass.send(:current_instances_key) if klass.respond_to?(:current_instances_key, true) # warm (private)
    defaults = klass.instance_variable_get(:@__class_attr_defaults)
    if defaults && !Ractor.shareable?(defaults)
      begin
        klass.instance_variable_set(:@__class_attr_defaults, Ractor.make_shareable(defaults.dup))
      rescue Ractor::Error, Ractor::IsolationError
      end
    end
    # Reset callbacks are made shareable centrally by
    # ActiveSupport::Callbacks.make_shareable.
  end
end
