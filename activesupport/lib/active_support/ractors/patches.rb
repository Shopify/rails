# frozen_string_literal: true

# ActiveSupport Ractor patches, applied by Rails::Application#ractorize!.
#
# Behavioral patches (module prepends) are applied at require time (during
# ractorize!, when all constants are loaded). Freeze/warm actions are registered
# as before_freeze/on_freeze callbacks run around make_shareable.

require "active_support/ractors/logger"

module ActiveSupport
  module Ractors
    module CallbacksRunFallback # :nodoc:
      # Making a whole callback chain shareable is deep (compiled callback
      # lambdas bound to unshareable self, a Mutex, unshareable terminators). In
      # a non-main Ractor where the chain can't be read, run the protected block
      # directly without the surrounding callbacks.
      def run_callbacks(*args, &block)
        super
      rescue Ractor::IsolationError
        raise if Ractor.main?
        block ? block.call : true
      end
    end

    module NotificationsFallback # :nodoc:
      # The global @notifier (a Fanout with subscribers and mutexes) isn't
      # shareable. In a non-main Ractor, run instrumented blocks without
      # publishing, and hand out a no-op instrumenter.
      def instrument(name, payload = {}, &block)
        super
      rescue Ractor::IsolationError
        raise if Ractor.main?
        block ? yield(payload) : nil
      end

      def instrumenter
        super
      rescue Ractor::IsolationError
        raise if Ractor.main?
        ActiveSupport::Notifications::NullInstrumenter.new
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

ActiveSupport::Callbacks.prepend(ActiveSupport::Ractors::CallbacksRunFallback)
ActiveSupport::Notifications.singleton_class.prepend(ActiveSupport::Ractors::NotificationsFallback)
ActiveSupport::ErrorReporter.prepend(ActiveSupport::Ractors::ErrorReporterFallback)
ActiveSupport::LogSubscriber.singleton_class.prepend(ActiveSupport::Ractors::LogSubscriberFallback)
ActiveSupport::Logger.prepend(ActiveSupport::Ractors::Logger::ShareableDevice)

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
  ActiveSupport::CurrentAttributes.descendants.each do |klass|
    klass.send(:current_instances_key) # warm @current_instances_key (private)
    defaults = klass.instance_variable_get(:@__class_attr_defaults)
    if defaults && !Ractor.shareable?(defaults)
      begin
        klass.instance_variable_set(:@__class_attr_defaults, Ractor.make_shareable(defaults.dup))
      rescue Ractor::Error, Ractor::IsolationError
      end
    end
  end
end
