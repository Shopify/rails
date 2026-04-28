# frozen_string_literal: true

module ActionView # :nodoc:
  class Template # :nodoc:
    # = Action View Template Handlers
    module Handlers # :nodoc:
      autoload :Raw, "action_view/template/handlers/raw"
      autoload :ERB, "action_view/template/handlers/erb"
      autoload :Html, "action_view/template/handlers/html"
      autoload :Builder, "action_view/template/handlers/builder"

      def self.extended(base)
        base.register_default_template_handler :raw, Raw.new
        base.register_template_handler :erb, ERB.new
        base.register_template_handler :html, Html.new
        base.register_template_handler :builder, Builder.new
        base.register_template_handler :ruby, lambda { |_, source| source }
      end

      @@template_handlers = {}
      @@default_template_handlers = nil

      def self.extensions
        @@template_extensions ||= @@template_handlers.keys
      end

      # Make this module's class-variable state shareable for non-main Ractor
      # access. +Handlers.extensions+ is invoked from
      # +ActionView::LookupContext::Accessors::DEFAULT_PROCS[:handlers]+ on
      # every per-request +initialize_details+ call, which reads
      # +@@template_extensions+ from inside the request Ractor. Per Aaron
      # Patterson's class-variable rules (+ab32c0e690+), reading a class
      # variable from a non-main Ractor only succeeds when its value is
      # shareable. Force the lazy +@@template_extensions+ build, then deeply
      # freeze each registered handler instance and the registry hashes. After
      # this call +register_template_handler+ /
      # +unregister_template_handler+ raise +FrozenError+ pointing back here.
      # Idempotent.
      def self.make_shareable!
        return if @@template_handlers.frozen?

        @@template_handlers.each_value do |handler|
          if handler.respond_to?(:make_shareable!)
            handler.make_shareable!
          else
            Ractor.make_shareable(handler)
          end
        end

        if @@default_template_handlers
          if @@default_template_handlers.respond_to?(:make_shareable!)
            @@default_template_handlers.make_shareable!
          else
            Ractor.make_shareable(@@default_template_handlers)
          end
        end

        # Force lazy build of @@template_extensions and freeze it.
        extensions
        @@template_extensions = @@template_extensions.dup.freeze

        @@template_handlers = @@template_handlers.dup.freeze
      end

      # Register an object that knows how to handle template files with the given
      # extensions. This can be used to implement new template types.
      # The handler must respond to +:call+, which will be passed the template
      # and should return the rendered template as a String.
      def register_template_handler(*extensions, handler)
        raise(ArgumentError, "Extension is required") if extensions.empty?
        if @@template_handlers.frozen?
          raise FrozenError, "ActionView::Template::Handlers registry is frozen after ractorize!; cannot register #{extensions.inspect}"
        end
        extensions.each do |extension|
          @@template_handlers[extension.to_sym] = handler
        end
        @@template_extensions = nil
      end

      # Opposite to register_template_handler.
      def unregister_template_handler(*extensions)
        if @@template_handlers.frozen?
          raise FrozenError, "ActionView::Template::Handlers registry is frozen after ractorize!; cannot unregister #{extensions.inspect}"
        end
        extensions.each do |extension|
          handler = @@template_handlers.delete extension.to_sym
          @@default_template_handlers = nil if @@default_template_handlers == handler
        end
        @@template_extensions = nil
      end

      def template_handler_extensions
        @@template_handlers.keys.map(&:to_s).sort
      end

      def registered_template_handler(extension)
        extension && @@template_handlers[extension.to_sym]
      end

      def register_default_template_handler(extension, klass)
        register_template_handler(extension, klass)
        @@default_template_handlers = klass
      end

      def handler_for_extension(extension)
        registered_template_handler(extension) || @@default_template_handlers
      end
    end
  end
end
