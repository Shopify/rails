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
        base.register_template_handler :ruby, ActiveSupport::Ractors.shareable_lambda { |_, source| source }
      end

      @@template_handlers = {}.freeze
      @@template_extensions = [].freeze
      @@default_template_handlers = nil

      def self.extensions
        @@template_extensions
      end

      def register_template_handler(*extensions, handler)
        raise(ArgumentError, "Extension is required") if extensions.empty?
        handler = ActiveSupport::Ractors.make_shareable(handler)
        handlers = @@template_handlers
        extensions.each do |extension|
          handlers = handlers.merge(extension.to_sym => handler)
        end
        @@template_handlers = handlers.freeze
        @@template_extensions = @@template_handlers.keys.freeze
      end

      # Opposite to register_template_handler.
      def unregister_template_handler(*extensions)
        handlers = @@template_handlers
        extensions.each do |extension|
          handler = handlers[extension.to_sym]
          handlers = handlers.except(extension.to_sym)
          @@default_template_handlers = nil if @@default_template_handlers == handler
        end
        @@template_handlers = handlers.freeze
        @@template_extensions = @@template_handlers.keys.freeze
      end

      def template_handler_extensions
        @@template_handlers.keys.map(&:to_s).sort
      end

      def registered_template_handler(extension)
        extension && @@template_handlers[extension.to_sym]
      end

      def register_default_template_handler(extension, klass)
        register_template_handler(extension, klass)
        @@default_template_handlers = registered_template_handler(extension)
      end

      def handler_for_extension(extension)
        registered_template_handler(extension) || @@default_template_handlers
      end
    end
  end
end
