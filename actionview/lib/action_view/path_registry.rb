# frozen_string_literal: true

module ActionView # :nodoc:
  module PathRegistry # :nodoc:
    @view_paths_by_class = {}
    @file_system_resolvers = {}
    @file_system_resolver_mutex = Mutex.new
    @file_system_resolver_hooks = []

    class << self
      attr_reader :file_system_resolver_hooks
    end

    def self.get_view_paths(klass)
      @view_paths_by_class[klass] || get_view_paths(klass.superclass)
    end

    def self.set_view_paths(klass, paths)
      if @file_system_resolver_mutex.nil?
        raise FrozenError,
          "ActionView::PathRegistry has been frozen for Ractor safety; " \
          "view paths must be configured during boot, before " \
          "Rails.application.ractorize!. (e.g. via controller class " \
          "bodies or Rails::Engine `config.paths`.)"
      end
      @view_paths_by_class[klass] = paths
    end

    def self.cast_file_system_resolvers(paths)
      paths = Array(paths)

      if @file_system_resolver_mutex.nil?
        raise FrozenError,
          "ActionView::PathRegistry has been frozen for Ractor safety; " \
          "file system resolvers must be registered during boot, before " \
          "Rails.application.ractorize!. (e.g. via controller class " \
          "bodies or Rails::Engine `config.paths`.)"
      end

      @file_system_resolver_mutex.synchronize do
        built_resolver = false
        paths = paths.map do |path|
          case path
          when String, Pathname
            path = File.expand_path(path)
            @file_system_resolvers[path] ||=
              begin
                built_resolver = true
                FileSystemResolver.new(path)
              end
          else
            path
          end
        end

        file_system_resolver_hooks.each(&:call) if built_resolver
      end

      paths
    end

    def self.all_resolvers
      resolvers = [all_file_system_resolvers]
      resolvers.concat @view_paths_by_class.values.map(&:to_a)
      resolvers.flatten.uniq
    end

    def self.all_file_system_resolvers
      @file_system_resolvers.values
    end

    # Make the four module-level ivars (+@view_paths_by_class+,
    # +@file_system_resolvers+, +@file_system_resolver_mutex+,
    # +@file_system_resolver_hooks+) Ractor-shareable so non-main Ractors
    # can read them without hitting +Ractor::IsolationError+ on the ivar
    # itself.
    #
    # Both +ExceptionWrapper#build_backtrace+ and per-request
    # +ViewPaths#lookup_context+ instantiation read +@view_paths_by_class+
    # and +@file_system_resolvers+ from inside the request Ractor; the
    # values stored there must therefore be shareable, not just frozen.
    #
    # Before cascading the freeze, we eager-warm every registered
    # +FileSystemResolver+ by walking its +all_template_paths+ and
    # building an +UnboundTemplate+ (plus an empty-locals +Template+
    # binding) for each one. This populates the resolver caches so that:
    #
    #   * +Resolver#built_templates+ returns the real warmed Templates,
    #     keeping +ExceptionWrapper#build_backtrace+'s
    #     compiled-method-name → source-file mapping working in
    #     production error pages.
    #   * Post-freeze +_find_all+ hits return the shareable
    #     UnboundTemplate cached at boot, so requests with empty (or
    #     strict-locals-default) locals reuse the same +Template+ across
    #     requests rather than building a fresh +Template+ per call.
    #     A fresh +Template+ per call would leak methods on
    #     +compiled_method_container+ since +Template#method_name+
    #     embeds +__id__+. With the eager-warm + per-Ractor compile
    #     guard in +Template#compile!+, the method count is bounded by
    #     +(warmed templates) * (containers) * (Ractors)+.
    #
    # Each registered +FileSystemResolver+ overrides +make_shareable!+
    # to snapshot its +Concurrent::Map+ template cache to a frozen
    # +Hash+; +UnboundTemplate#make_shareable!+ snapshots its own
    # +@templates+ map and cascades into each cached +Template+.
    # The PathSets stored under +@view_paths_by_class+ already wrap a
    # frozen +@paths+ Array of those same shareable resolvers.
    #
    # The boot-only +@file_system_resolver_mutex+ is set to +nil+;
    # +set_view_paths+ and +cast_file_system_resolvers+ branch on it to
    # raise a clear +FrozenError+ if anything tries to register more
    # view paths or resolvers post-+ractorize!+. The hooks Array
    # (populated only by +ActionView::CacheExpiry::ViewReloader+ in
    # development) is frozen as-is; in production it's empty.
    def self.make_shareable! # :nodoc:
      return self if @file_system_resolver_mutex.nil?

      @file_system_resolvers.each_value(&:eager_load_paths!)

      @file_system_resolvers.each_value(&:make_shareable!)
      @view_paths_by_class.each_value(&:make_shareable!)

      @file_system_resolvers.freeze
      @view_paths_by_class.freeze
      @file_system_resolver_hooks.freeze
      @file_system_resolver_mutex = nil

      self
    end
  end
end
