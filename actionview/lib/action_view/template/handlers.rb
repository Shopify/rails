# frozen_string_literal: true

module ActionView # :nodoc:
  class Template # :nodoc:
    # = Action View Template Handlers
    module Handlers # :nodoc:
      autoload :Raw, "action_view/template/handlers/raw"
      autoload :ERB, "action_view/template/handlers/erb"
      autoload :Html, "action_view/template/handlers/html"
      autoload :Builder, "action_view/template/handlers/builder"

      @template_handlers = {}
      @default_template_handlers = nil

      def self.ractor_shareable
        @template_handlers[:ruby] = Ractor.shareable_proc(&@template_handlers[:ruby])
        freeze
      end

      def self.freeze
        @template_extensions.each(&:freeze).freeze
        @template_handlers.each_value(&:freeze).freeze
        super
      end

      def self.extensions
        @template_extensions ||= @template_handlers.keys
      end

      # Register an object that knows how to handle template files with the given
      # extensions. This can be used to implement new template types.
      # The handler must respond to +:call+, which will be passed the template
      # and should return the rendered template as a String.
      def self.register_template_handler(*extensions, handler)
        raise(ArgumentError, "Extension is required") if extensions.empty?
        extensions.each do |extension|
          @template_handlers[extension.to_sym] = handler
        end
        @template_extensions = nil
      end

      def register_template_handler(...)
        ::ActionView::Template::Handlers.register_template_handler(...)
      end

      # Opposite to register_template_handler.
      def self.unregister_template_handler(*extensions)
        extensions.each do |extension|
          handler = @template_handlers.delete extension.to_sym
          @default_template_handlers = nil if @default_template_handlers == handler
        end
        @template_extensions = nil
      end

      def self.template_handler_extensions
        @template_handlers.keys.map(&:to_s).sort
      end

      def self.registered_template_handler(extension)
        extension && @template_handlers[extension.to_sym]
      end

      def self.register_default_template_handler(extension, klass)
        register_template_handler(extension, klass)
        @default_template_handlers = klass
      end

      def self.handler_for_extension(extension)
        registered_template_handler(extension) || @default_template_handlers
      end

      def handler_for_extension(...)
        ::ActionView::Template::Handlers.handler_for_extension(...)
      end

      register_default_template_handler :raw, Raw.new
      register_template_handler :erb, ERB.new
      register_template_handler :html, Html.new
      register_template_handler :builder, Builder.new
      register_template_handler :ruby, lambda { |_, source| source }
    end
  end
end
