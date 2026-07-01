# frozen_string_literal: true

# Action View Ractor patches, applied by Rails::Application#ractorize!.

require "active_support/ractors"

module ActionView
  module RactorPatches # :nodoc:
    # Resolvers hold a mutable Concurrent::Map template cache and a memoized
    # Regexp parser -- used only for file-template lookup. Rendering inline
    # content never touches them, so shed them on freeze (a full solution would
    # use Ractor-local template caches).
    module ResolverShareable
      def freeze
        @unbound_templates = {}.freeze if instance_variable_defined?(:@unbound_templates)
        @path_parser = nil if instance_variable_defined?(:@path_parser)
        super
      end
    end

    module PathRegistry
      def all_resolvers
        super
      rescue Ractor::IsolationError
        raise if Ractor.main?
        []
      end

      def all_file_system_resolvers
        super
      rescue Ractor::IsolationError
        raise if Ractor.main?
        []
      end
    end

    # DetailsKey.view_context_class memoizes an anonymous ActionView::Base
    # subclass under a Mutex; once warmed the class is shareable.
    module DetailsKey
      def view_context_class
        return super if Ractor.main?
        @view_context_class
      end
    end

    # Rendering::ClassMethods#view_context_class rebuilds when klass.changed?,
    # which calls #compiled_method_container (defined with an unshareable Proc).
    # In a frozen app the class never changes; return the warmed value.
    module RenderingClassMethods
      def view_context_class
        return super if Ractor.main?
        @view_context_class
      end
    end
  end
end

ActiveSupport::Ractors.before_freeze do
  ActionView::Resolver.prepend(ActionView::RactorPatches::ResolverShareable)
  ActionView::PathRegistry.singleton_class.prepend(ActionView::RactorPatches::PathRegistry)
  ActionView::LookupContext::DetailsKey.singleton_class.prepend(ActionView::RactorPatches::DetailsKey)
  ActionView::Rendering::ClassMethods.prepend(ActionView::RactorPatches::RenderingClassMethods)
end

ActiveSupport::Ractors.capture_class_reader(ActionView::Base, :default_formats)

ActiveSupport::Ractors.on_freeze do
  registry = ActionView::PathRegistry
  %i[@view_paths_by_class @file_system_resolvers].each do |ivar|
    value = registry.instance_variable_get(ivar)
    next if value.nil? || Ractor.shareable?(value)
    registry.instance_variable_set(ivar, Ractor.make_shareable(value))
  end

  # LookupContext.default_procs: at request time only its keys are read
  # (registered_details); the register_detail-defined `default_<name>` methods
  # are separately defined with unshareable blocks -- redefine them shareable.
  procs = ActionView::LookupContext.default_procs
  shareable = procs.to_h do |key, value|
    [key, Ractor.shareable?(value) ? value : Ractor.shareable_proc(&value)]
  end
  ActionView::LookupContext.default_procs = Ractor.make_shareable(shareable) unless Ractor.shareable?(procs)
  shareable.each do |name, proc|
    ActionView::LookupContext::Accessors.define_method(:"default_#{name}", &proc)
  end

  ActionView::LookupContext::DetailsKey.view_context_class # warm @view_context_class
end
