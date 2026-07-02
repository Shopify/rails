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
        # The path parser memoizes a Regexp; warm it, then make it shareable so a
        # non-main Ractor can reuse the frozen parser.
        if instance_variable_defined?(:@path_parser) && @path_parser
          @path_parser.parse("warm/warm.html.erb") rescue nil
          @path_parser = Ractor.make_shareable(@path_parser) rescue @path_parser
        end
        # The unbound-template cache is a Concurrent::Map (can't be frozen); drop
        # it and use a Ractor-local cache instead (see #_find_all below).
        if instance_variable_defined?(:@unbound_templates)
          @unbound_templates = nil
          @ractor_unbound_key = :"__ractor_resolver_unbound_#{object_id}"
        end
        super
      end

      def built_templates
        return [] if instance_variable_defined?(:@unbound_templates) && @unbound_templates.nil?
        super
      end

      private
        def _find_all(name, prefix, partial, details, key, locals)
          return super if @unbound_templates || Ractor.main?

          requested_details = key || TemplateDetails::Requested.new(**details)
          cache = key ? (Ractor[@ractor_unbound_key] ||= Concurrent::Map.new) : Concurrent::Map.new
          unbound_templates =
            cache.compute_if_absent(TemplatePath.virtual(name, prefix, partial)) do
              path = TemplatePath.build(name, prefix, partial)
              unbound_templates_from_path(path)
            end
          filter_and_sort_by_details(unbound_templates, requested_details).map do |unbound_template|
            unbound_template.bind_locals(locals)
          end
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

      # @details_keys / @digest_cache are Concurrent::Map class-ivar caches that a
      # non-main Ractor can't read/write. Compute without the shared cache.
      def details_cache_key(details)
        return super if Ractor.main?
        if (formats = details[:formats]) && (normalized = Template.normalized_formats(formats))
          details = details.dup
          details[:formats] = normalized
        end
        TemplateDetails::Requested.new(**details)
      end

      def digest_cache(details)
        return super if Ractor.main?
        Concurrent::Map.new
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

    # Digestor.digest uses a class-variable mutex (@@digest_mutex) around a
    # (now Ractor-local) finder digest cache. In a non-main Ractor, compute the
    # digest without the shared mutex.
    module Digestor
      def digest(name:, format: nil, finder:, dependencies: nil)
        return super if Ractor.main?

        cache_key =
          if dependencies.nil? || dependencies.empty?
            "#{name}.#{format}"
          else
            "#{name}.#{format}.#{dependencies.flatten.tap(&:compact!).join('.')}"
          end

        finder.digest_cache[cache_key] ||= begin
          path = ActionView::TemplatePath.parse(name)
          root = tree(path.to_s, finder, path.partial?)
          if dependencies
            dependencies.each { |dep| root.children << ActionView::Digestor::Injected.new(dep, nil, nil) }
          end
          root.digest(finder)
        end
      end
    end
  end
end

ActiveSupport::Ractors.before_freeze do
  ([ActionView::Resolver, ActionView::FileSystemResolver] + ActionView::FileSystemResolver.descendants).uniq.each do |klass|
    klass.prepend(ActionView::RactorPatches::ResolverShareable)
  end
  ActionView::PathRegistry.singleton_class.prepend(ActionView::RactorPatches::PathRegistry)
  ActionView::LookupContext::DetailsKey.singleton_class.prepend(ActionView::RactorPatches::DetailsKey)
  ActionView::Digestor.singleton_class.prepend(ActionView::RactorPatches::Digestor)

  # Form field tag classes memoize @field_type; warm it so a non-main Ractor
  # doesn't try to set the class ivar while rendering form fields.
  if defined?(ActionView::Helpers::Tags)
    ActionView::Helpers::Tags.constants.each do |const|
      klass = ActionView::Helpers::Tags.const_get(const)
      next unless klass.is_a?(Class) && klass.respond_to?(:field_type)
      klass.field_type
      if klass.instance_variable_defined?(:@field_type)
        klass.instance_variable_set(:@field_type, Ractor.make_shareable(klass.instance_variable_get(:@field_type)))
      end
    end
  end
  ActionView::Rendering::ClassMethods.prepend(ActionView::RactorPatches::RenderingClassMethods)
end

ActiveSupport::Ractors.capture_class_reader(ActionView::Helpers::SanitizeHelper, :sanitizer_vendor)
ActiveSupport::Ractors.capture_class_reader(ActionView::Base, :default_formats)
ActiveSupport::Ractors.capture_class_reader(ActionView::Template::Handlers::ERB, :escape_ignore_list)
ActiveSupport::Ractors.capture_class_reader(ActionView::Base, :annotate_rendered_view_with_filenames)
ActiveSupport::Ractors.capture_class_reader(ActionView::Base, :default_form_builder)
ActiveSupport::Ractors.capture_class_reader(ActionView::Base, :remove_hidden_field_autocomplete)
ActiveSupport::Ractors.capture_class_reader(ActionView::Base, :automatically_disable_submit_tag)
ActiveSupport::Ractors.capture_class_reader(ActionView::Base, :streaming_completion_on_exception)

# AssetTagHelper mattr_accessors read as instance methods while rendering asset
# tags (image_tag, stylesheet_link_tag, ...).
%i[image_loading image_decoding preload_links_header apply_stylesheet_media_default
   auto_include_nonce_for_scripts auto_include_nonce_for_styles].each do |name|
  ActiveSupport::Ractors.capture_instance_reader(ActionView::Helpers::AssetTagHelper, name)
end

# FormHelper / FormTagHelper mattr_accessors read as instance methods while
# rendering forms (form_with, etc.).
%i[form_with_generates_remote_forms form_with_generates_ids
   multiple_file_field_include_hidden].each do |name|
  ActiveSupport::Ractors.capture_instance_reader(ActionView::Helpers::FormHelper, name)
end
%i[embed_authenticity_token_in_remote_forms default_enforce_utf8].each do |name|
  ActiveSupport::Ractors.capture_instance_reader(ActionView::Helpers::FormTagHelper, name)
end
if defined?(ActionView::Helpers::ContentExfiltrationPreventionHelper)
  ActiveSupport::Ractors.capture_instance_reader(ActionView::Helpers::ContentExfiltrationPreventionHelper, :prepend_content_exfiltration_prevention)
end

ActiveSupport::Ractors.on_freeze do
  # ERB compiler constants read while compiling a template in a Ractor.
  if defined?(ActionView::Template::Handlers::ERB::ENCODING_TAG)
    Ractor.make_shareable(ActionView::Template::Handlers::ERB::ENCODING_TAG)
  end
  if defined?(ActionView::AbstractRenderer::RenderedTemplate::EMPTY_SPACER)
    Ractor.make_shareable(ActionView::AbstractRenderer::RenderedTemplate::EMPTY_SPACER)
  end

  # DependencyTracker.@trackers is a Concurrent::Map class ivar (registered at
  # boot, read at request time). Replace with a shareable Hash so a non-main
  # Ractor can read it.
  if defined?(ActionView::DependencyTracker)
    trackers = ActionView::DependencyTracker.instance_variable_get(:@trackers)
    if trackers && !Ractor.shareable?(trackers)
      plain = {}
      trackers.each { |k, v| plain[k] = v }
      ActionView::DependencyTracker.instance_variable_set(:@trackers, Ractor.make_shareable(plain))
    end
  end

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
