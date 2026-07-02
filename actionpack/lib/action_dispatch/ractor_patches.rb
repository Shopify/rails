# frozen_string_literal: true

# ActionPack Ractor patches, applied by Rails::Application#ractorize!.

require "active_support/ractors"

module ActionDispatch
  module RactorPatches # :nodoc:
    # A RouteSet keeps the blocks passed to routes.prepend/append to replay on a
    # route reload; those close over the unshareable application. A frozen app
    # never reloads, so drop them on freeze.
    module RouteSet
      def freeze
        @prepend&.clear
        @append&.clear
        super
      end
    end

    # direct/resolve helpers store a block invoked via instance_exec (which
    # rebinds self), so a self-detached shareable proc is safe.
    module CustomUrlHelper
      def freeze
        if block && !Ractor.shareable?(block)
          @block = Ractor.shareable_proc(&block)
        end
        super
      end
    end

    # ServerTiming::Subscriber keeps a Mutex that only guards a one-time
    # Notifications subscription; subscribe, then drop it.
    module ServerTimingSubscriber
      def freeze
        ensure_subscribed
        @mutex = nil
        super
      end
    end

    # ExceptionWrapper reads class variables (@@rescue_responses) and other
    # main-Ractor-only state; degrade so the primary error still propagates.
    module ExceptionWrapper
      def unwrapped_exception
        super
      rescue Ractor::IsolationError
        raise if Ractor.main?
        exception
      end
    end

    module ExceptionWrapperClass
      def status_code_for_exception(class_name)
        return super if Ractor.main?
        ActionDispatch::Response.rack_status_code(rescue_responses[class_name])
      end
    end

    # ShowExceptions/DebugExceptions read class variables while rendering an
    # error page; in a Ractor, bypass so the original exception propagates.
    module ExceptionMiddlewarePassthrough
      def call(env)
        return @app.call(env) unless Ractor.main?
        super
      end
    end

    CONTROLLER_SHAREABLE_ATTRS = %i[
      @__class_attr_config
      @__class_attr_middleware_stack
      @controller_path
      @controller_name
      @_prefixes
      @action_methods
      @renderer
      @__class_attr__renderers
      @__class_attr_helpers_path
      @__class_attr__wrapper_options
      @__class_attr_rescue_handlers
      @__class_attr_etaggers
      @__class_attr_fragment_cache_keys
      @__class_attr__layout
      @__class_attr__layout_conditions
      @__class_attr_default_url_options
    ].freeze

    def self.share_class_ivars!(klass, ivars)
      ivars.each do |ivar|
        next unless klass.instance_variable_defined?(ivar)
        val = klass.instance_variable_get(ivar)
        next if Ractor.shareable?(val)
        begin
          klass.instance_variable_set(ivar, Ractor.make_shareable(val))
        rescue Ractor::Error, Ractor::IsolationError
        end
      end
    end

    def self.make_controllers_shareable!
      klasses = ActionController::Base.descendants +
        [ActionController::Metal, ActionController::Base, AbstractController::Base]
      klasses.uniq.each do |klass|
        klass.view_context_class if klass.respond_to?(:view_context_class) && klass.respond_to?(:_routes)
        klass._prefixes if klass.respond_to?(:_prefixes)
        klass.controller_name if klass.respond_to?(:controller_name)
        share_class_ivars!(klass, CONTROLLER_SHAREABLE_ATTRS)
        # Callback chains are made shareable centrally by
        # ActiveSupport::Callbacks.make_shareable.
      end
    end
  end
end

ActiveSupport::Ractors.before_freeze do
  # URL generation lazily memoizes on Journey routes/AST and the formatter cache
  # (Route#parts/required_parts/required_defaults, Node#to_s, Formatter#cache).
  # Warm them on the main Ractor before the route set is frozen so generation
  # works from a non-main Ractor.
  if defined?(Rails) && Rails.application
    Rails.application.routes.eager_load! rescue nil
  end

  ActionDispatch::Routing::RouteSet.prepend(ActionDispatch::RactorPatches::RouteSet)
  ActionDispatch::Routing::RouteSet::CustomUrlHelper.prepend(ActionDispatch::RactorPatches::CustomUrlHelper)
  ActionDispatch::ServerTiming::Subscriber.prepend(ActionDispatch::RactorPatches::ServerTimingSubscriber)
  ActionDispatch::ExceptionWrapper.prepend(ActionDispatch::RactorPatches::ExceptionWrapper)
  ActionDispatch::ExceptionWrapper.singleton_class.prepend(ActionDispatch::RactorPatches::ExceptionWrapperClass)
  ActionDispatch::ShowExceptions.prepend(ActionDispatch::RactorPatches::ExceptionMiddlewarePassthrough)
  ActionDispatch::DebugExceptions.prepend(ActionDispatch::RactorPatches::ExceptionMiddlewarePassthrough)
end

# Class-level readers backed by class variables that the request path reads.
ActiveSupport::Ractors.capture_class_reader(ActionDispatch::Response, :default_headers)
ActiveSupport::Ractors.capture_class_reader(ActionDispatch::Response, :default_charset)
ActiveSupport::Ractors.capture_class_reader(ActionDispatch::ParamBuilder, :default)
ActiveSupport::Ractors.capture_class_reader(ActionDispatch::Request, :ignore_accept_header)
ActiveSupport::Ractors.capture_class_reader(ActionDispatch::Request, :strict_accept_header)
ActiveSupport::Ractors.capture_class_reader(ActionDispatch::ExceptionWrapper, :rescue_responses)

# The url_helpers module defines `_routes` capturing the route set in an
# unshareable proc. After ractorize! the route set is frozen (shareable) while
# modules are still mutable, so redefine `_routes` with a shareable proc then.
ActiveSupport::Ractors.on_freeze do
  if defined?(Rails) && Rails.application
    app_routes = Rails.application.routes
    shareable_routes = app_routes
    mod = app_routes.url_helpers
    mod.define_method(:_routes, &Ractor.shareable_proc { @_routes || shareable_routes })

    # `Rails.application.routes.url_helpers.some_path` calls the helper as a
    # singleton method of the url_helpers module, whose singleton `_routes`
    # reads @_proxy (a module ivar). Redefine it to return the frozen route set
    # and make @_proxy shareable so the other singleton delegators work too.
    mod.singleton_class.define_method(:_routes, &Ractor.shareable_proc { shareable_routes })
    # UrlFor gives each including module/class a `default_url_options` class
    # attribute defaulting to a mutable {}. Freeze it so url_options can read it
    # from a non-main Ractor.
    freeze_default_url_options = lambda do |obj|
      next unless obj.respond_to?(:default_url_options) && obj.respond_to?(:default_url_options=)
      val = obj.default_url_options
      next if val.nil? || Ractor.shareable?(val)
      obj.default_url_options = Ractor.make_shareable(val.dup)
    rescue Ractor::Error, Ractor::IsolationError, FrozenError
    end

    freeze_default_url_options.call(mod)
    if mod.instance_variable_defined?(:@_proxy)
      proxy = mod.instance_variable_get(:@_proxy)
      freeze_default_url_options.call(proxy.class)
      begin
        mod.instance_variable_set(:@_proxy, Ractor.make_shareable(proxy))
      rescue Ractor::Error, Ractor::IsolationError
      end
    end
  end
end

ActiveSupport::Ractors.on_freeze do
  Ractor.make_shareable(Mime::SET)
  Ractor.make_shareable(Mime::LOOKUP)
  Ractor.make_shareable(Mime::EXTENSION_LOOKUP)
  Ractor.make_shareable(Mime::ALL)
  Ractor.make_shareable(ActionDispatch::FileHandler.const_get(:DEFAULT_UTF8_CONTENT_TYPES))
  Ractor.make_shareable(ActionDispatch::FileHandler.const_get(:PRECOMPRESSED))

  ActionDispatch::RactorPatches.make_controllers_shareable!

  parsers = ActionDispatch::Request.parameter_parsers
  unless Ractor.shareable?(parsers)
    shareable = parsers.to_h do |mime, parser|
      [mime, Ractor.shareable?(parser) ? parser : Ractor.shareable_proc(&parser)]
    end
    ActionDispatch::Request.instance_variable_set(:@parameter_parsers, Ractor.make_shareable(shareable))
  end
end
