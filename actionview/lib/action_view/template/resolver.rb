# frozen_string_literal: true

require "pathname"
require "active_support/core_ext/class"
require "active_support/core_ext/module/attribute_accessors"
require "action_view/template"
require "concurrent/map"

module ActionView
  # = Action View Resolver
  class Resolver
    class PathParser # :nodoc:
      ParsedPath = Struct.new(:path, :details)

      def build_path_regex
        handlers = Regexp.union(Template::Handlers.extensions.map(&:to_s))
        formats = Regexp.union(Template::Types.symbols.map(&:to_s))
        available_locales = I18n.available_locales.map(&:to_s)
        regular_locales = [/[a-z]{2}(?:[-_][A-Z]{2})?/]
        locales = Regexp.union(available_locales + regular_locales)
        variants = "[^.]*"

        %r{
          \A
          (?:(?<prefix>.*)/)?
          (?<partial>_)?
          (?<action>.*?)
          (?:\.(?<locale>#{locales}))??
          (?:\.(?<format>#{formats}))??
          (?:\+(?<variant>#{variants}))??
          (?:\.(?<handler>#{handlers}))?
          \z
        }x
      end

      def parse(path)
        @regex ||= build_path_regex
        match = @regex.match(path)
        path = TemplatePath.build(match[:action], match[:prefix] || "", !!match[:partial])
        details = TemplateDetails.new(
          match[:locale]&.to_sym,
          match[:handler]&.to_sym,
          match[:format]&.to_sym,
          match[:variant]&.to_sym
        )
        ParsedPath.new(path, details)
      end

      # Force compilation of +@regex+ so subsequent +parse+ calls only read,
      # never write, the lazy ivar. After +ractorize!+ the parser is shared
      # across Ractors via +FileSystemResolver+, and non-main Ractors may
      # not write to a frozen object's ivars.
      def make_shareable! # :nodoc:
        return self if frozen?
        @regex ||= build_path_regex
        super
      end
    end

    cattr_accessor :caching, default: true

    class << self
      alias :caching? :caching
    end

    def clear_cache
    end

    # Normalizes the arguments and passes it on to find_templates.
    def find_all(name, prefix = nil, partial = false, details = {}, key = nil, locals = [])
      _find_all(name, prefix, partial, details, key, locals)
    end

    def built_templates # :nodoc:
      # Used for error pages
      []
    end

    def all_template_paths # :nodoc:
      # Not implemented by default
      []
    end

  private
    def _find_all(name, prefix, partial, details, key, locals)
      find_templates(name, prefix, partial, details, locals)
    end

    delegate :caching?, to: :class

    # This is what child classes implement. No defaults are needed
    # because Resolver guarantees that the arguments are present and
    # normalized.
    def find_templates(name, prefix, partial, details, locals = [])
      raise NotImplementedError, "Subclasses must implement a find_templates(name, prefix, partial, details, locals = []) method"
    end
  end

  # A resolver that loads files from the filesystem.
  class FileSystemResolver < Resolver
    attr_reader :path

    def initialize(path)
      raise ArgumentError, "path already is a Resolver class" if path.is_a?(Resolver)
      @unbound_templates = Concurrent::Map.new
      @path_parser = PathParser.new
      @path = File.expand_path(path)
      super()
    end

    def clear_cache
      @unbound_templates.clear
      @path_parser = PathParser.new
      super
    end

    def to_s
      @path.to_s
    end
    alias :to_path :to_s

    def eql?(resolver)
      self.class.equal?(resolver.class) && to_path == resolver.to_path
    end
    alias :== :eql?

    def all_template_paths # :nodoc:
      paths = template_glob("**/*")
      paths.map do |filename|
        filename.from(@path.size + 1).remove(/\.[^\/]*\z/)
      end.uniq.map do |filename|
        TemplatePath.parse(filename)
      end
    end

    def built_templates # :nodoc:
      @unbound_templates.values.flatten.flat_map(&:built_templates)
    end

    # Snapshot the per-resolver template cache so the resolver can be
    # deeply frozen and shared across Ractors. +@unbound_templates+ is a
    # +Concurrent::Map+, which doesn't implement +#freeze+ and whose
    # values (UnboundTemplate / Template) carry their own non-shareable
    # caches and locks. After +Rails.application.ractorize!+ the
    # resolver is read from non-main Ractors via +ActionView::PathRegistry+
    # (see +get_view_paths+, +all_file_system_resolvers+), so its
    # instance variables must hold shareable values.
    #
    # We snapshot the existing cache contents to a frozen +Hash+ and
    # cascade +make_shareable!+ into every +UnboundTemplate+ inside.
    # Callers that want post-freeze cache hits (rather than per-request
    # recomputation, which would defeat +built_templates+ for exception
    # source mapping and would re-define methods on the shared
    # +compiled_method_container+) should pre-warm the cache before
    # calling this — see +PathRegistry.make_shareable!+ and
    # +#eager_load_paths!+.
    #
    # +_find_all+ branches on +@unbound_templates.frozen?+: cache hits
    # return the warmed shareable +UnboundTemplate+s; cache misses fall
    # through to a local recompute (uncached, leaks per call).
    def make_shareable! # :nodoc:
      return self if frozen?
      @path_parser.make_shareable!

      snapshot = {}
      @unbound_templates.each_pair do |key, value|
        Array(value).each(&:make_shareable!)
        snapshot[key] = value.is_a?(Array) ? value.freeze : value
      end

      @unbound_templates = snapshot.freeze
      super
    end

    # Walk every template path under this resolver's root and populate
    # +@unbound_templates+ so subsequent +make_shareable!+ snapshots a
    # populated cache. Triggered by +PathRegistry.make_shareable!+ at
    # boot, before the cascade freeze. The eager pass does not bind
    # locals or compile templates — it just builds and caches the
    # +UnboundTemplate+ objects so +Resolver#built_templates+ has
    # entries for exception backtrace mapping and so post-freeze
    # +_find_all+ hits the cache instead of recomputing per call.
    #
    # We bypass +find_all+ here because +find_all+'s
    # +filter_and_sort_by_details+ wants a +TemplateDetails::Requested+
    # to match against, which would require speculatively iterating
    # every locale / format / variant combination. Instead, we replicate
    # the cache-write portion of +_find_all+ (the +compute_if_absent+
    # branch) directly: for each disk-discovered virtual path, read or
    # build the cached +UnboundTemplate+ list. Subsequent request-time
    # +_find_all+ calls hit the same +virtual_path+ key and skip the
    # disk glob.
    def eager_load_paths! # :nodoc:
      return if frozen?
      return if @unbound_templates.frozen?

      all_template_paths.each do |template_path|
        virtual_path = TemplatePath.virtual(template_path.name, template_path.prefix, template_path.partial?)
        unbound_templates = @unbound_templates.compute_if_absent(virtual_path) do
          unbound_templates_from_path(template_path)
        end
        # Bind with empty locals so each +UnboundTemplate+'s +@templates+
        # map has at least one +Template+ in it. Without this,
        # +built_templates+ would still return +[]+ because
        # +UnboundTemplate#built_templates+ reads +@templates.values+,
        # not +@unbound_templates+. The empty-locals Template is the
        # canonical instance for non-strict templates rendered without
        # explicit locals, and the only Template needed for strict-locals
        # templates (which short-circuit on the first +bind_locals+ to
        # populate +@templates+ with a default value).
        unbound_templates.each { |unbound| unbound.bind_locals([]) }
      end
    end

    private
      def _find_all(name, prefix, partial, details, key, locals)
        requested_details = key || TemplateDetails::Requested.new(**details)
        virtual_path = TemplatePath.virtual(name, prefix, partial)

        unbound_templates =
          if @unbound_templates.frozen?
            # Post-+make_shareable!+: cache is a read-only frozen Hash.
            # Hits return the warmed UnboundTemplates (already shareable
            # via the +make_shareable!+ cascade); misses fall through to
            # a local recompute. The recomputed UnboundTemplates are
            # used locally by the caller and never stored on the shared
            # resolver, so they don't need to be shareable themselves —
            # but their +Template#compile!+ will still mutate the shared
            # +compiled_method_container+'s method table (one method per
            # +__id__+), so misses are a known leak source. Pre-warming
            # in +PathRegistry.make_shareable!+ keeps this branch rare.
            @unbound_templates[virtual_path] || begin
              path = TemplatePath.build(name, prefix, partial)
              unbound_templates_from_path(path)
            end
          elsif key
            @unbound_templates.compute_if_absent(virtual_path) do
              path = TemplatePath.build(name, prefix, partial)
              unbound_templates_from_path(path)
            end
          else
            path = TemplatePath.build(name, prefix, partial)
            unbound_templates_from_path(path)
          end

        filter_and_sort_by_details(unbound_templates, requested_details).map do |unbound_template|
          unbound_template.bind_locals(locals)
        end
      end

      def source_for_template(template)
        Template::Sources::File.new(template)
      end

      def build_unbound_template(template)
        parsed = @path_parser.parse(template.from(@path.size + 1))
        details = parsed.details
        source = source_for_template(template)

        UnboundTemplate.new(
          source,
          template,
          details: details,
          virtual_path: parsed.path.virtual,
        )
      end

      def unbound_templates_from_path(path)
        if path.name.include?(".")
          return []
        end

        # Instead of checking for every possible path, as our other globs would
        # do, scan the directory for files with the right prefix.
        paths = template_glob("#{escape_entry(path.to_s)}*")

        paths.map do |path|
          build_unbound_template(path)
        end.select do |template|
          # Select for exact virtual path match, including case sensitivity
          template.virtual_path == path.virtual
        end
      end

      def filter_and_sort_by_details(templates, requested_details)
        filtered_templates = templates.select do |template|
          template.details.matches?(requested_details)
        end

        if filtered_templates.count > 1
          filtered_templates.sort_by! do |template|
            template.details.sort_key_for(requested_details)
          end
        end

        filtered_templates
      end

      # Safe glob within @path
      def template_glob(glob)
        query = File.join(escape_entry(@path), glob)
        path_with_slash = File.join(@path, "")

        Dir.glob(query).filter_map do |filename|
          filename = File.expand_path(filename)
          next if File.directory?(filename)
          next unless filename.start_with?(path_with_slash)

          filename
        end
      end

      def escape_entry(entry)
        entry.gsub(/[*?{}\[\]]/, '\\\\\\&')
      end
  end
end
