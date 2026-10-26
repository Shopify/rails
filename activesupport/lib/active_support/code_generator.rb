# :markup: markdown
# frozen_string_literal: true

module ActiveSupport
  class CodeGenerator # :nodoc:
    class MethodSet
      METHOD_CACHES = Hash.new { |h, k| h[k] = Module.new }

      def initialize(namespace, recorder = nil)
        @namespace = namespace
        @recorder = recorder
        @cache = recorder ? recorder.cache(namespace) : METHOD_CACHES[namespace]
        @sources = []
        @methods = {}
        @canonical_methods = {}
      end

      def define_cached_method(canonical_name, as: nil)
        canonical_name = canonical_name.to_sym
        as = (as || canonical_name).to_sym

        @methods.fetch(as) do
          unless @cache.method_defined?(canonical_name) || @canonical_methods[canonical_name]
            if @recorder
              first_line = @sources.size
              yield @sources
              @recorder.record_source(@namespace, canonical_name, @sources[first_line..].join("\n"))
            else
              yield @sources
            end
          end
          @canonical_methods[canonical_name] = true
          @methods[as] = canonical_name
        end
      end

      def apply(owner, path, line)
        unless @sources.empty?
          @cache.module_eval("# frozen_string_literal: true\n" + @sources.join(";"), path, line)
        end
        @canonical_methods.clear

        @methods.each do |as, canonical_name|
          owner.define_method(as, @cache.instance_method(canonical_name))
        end

        @recorder&.record_methods(owner, @namespace, @methods)
      end
    end

    # Records the source of every cached method and which methods each owner
    # received, so the result can be written out and bound again later without
    # running the code that decided it. While recording, methods are compiled
    # into private modules rather than METHOD_CACHES, so every source is
    # captured even if another owner compiled the same method earlier.
    class Recorder
      attr_reader :sources

      def initialize
        @caches = Hash.new { |h, k| h[k] = Module.new }
        @sources = Hash.new { |h, k| h[k] = {} }
        @methods = {}.compare_by_identity
      end

      def cache(namespace)
        @caches[namespace]
      end

      def record_source(namespace, canonical_name, source)
        @sources[namespace][canonical_name] = source
      end

      def record_methods(owner, namespace, methods)
        recorded = (@methods[owner] ||= [])
        methods.each { |as, canonical_name| recorded << [namespace, as, canonical_name] }
      end

      # Returns <tt>[namespace, as, canonical_name]</tt> for every method defined
      # on +owner+ since the last call, and forgets them.
      def take_methods(owner)
        @methods.delete(owner) || []
      end
    end

    class << self
      attr_reader :recorder

      # Records every batch run inside the block. Not thread-safe: meant for a
      # build step, not a running application.
      def record(recorder = Recorder.new)
        previous, @recorder = @recorder, recorder
        yield recorder
        recorder
      ensure
        @recorder = previous
      end

      def batch(owner, path, line)
        if owner.is_a?(CodeGenerator)
          yield owner
        else
          instance = new(owner, path, line)
          result = yield instance
          instance.execute
          result
        end
      end
    end

    def initialize(owner, path, line)
      @owner = owner
      @path = path
      @line = line
      recorder = CodeGenerator.recorder
      @namespaces = Hash.new { |h, k| h[k] = MethodSet.new(k, recorder) }
      @sources = []
    end

    def class_eval
      yield @sources
    end

    def define_cached_method(canonical_name, namespace:, as: nil, &block)
      @namespaces[namespace].define_cached_method(canonical_name, as: as, &block)
    end

    def execute
      @namespaces.each_value do |method_set|
        method_set.apply(@owner, @path, @line - 1)
      end

      unless @sources.empty?
        @owner.class_eval("# frozen_string_literal: true\n" + @sources.join(";"), @path, @line - 1)
      end
    end
  end
end
