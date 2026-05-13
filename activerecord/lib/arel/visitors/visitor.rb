# frozen_string_literal: true

module Arel # :nodoc: all
  module Visitors
    class Visitor
      def initialize
        @dispatch = get_dispatch_cache
      end

      def accept(object, collector = nil)
        visit object, collector
      end

      private
        attr_reader :dispatch

        # Per-Ractor dispatch caches. The class-level cache used to be a
        # plain Hash with a write-through default proc; after ractorize!
        # froze the class, the default proc was stripped and every miss
        # recomputed the symbol name without memoizing. Move the cache
        # into Ractor-local storage so each request-serving Ractor has a
        # writable Hash keyed by visitor subclass.
        def self.dispatch_cache
          caches = (Ractor[:_arel_dispatch_caches] ||= {}.compare_by_identity)
          caches[self] ||= Hash.new do |hash, klass|
            hash[klass] = :"visit_#{(klass.name || "").gsub("::", "_")}"
          end.compare_by_identity
        end

        def get_dispatch_cache
          self.class.dispatch_cache
        end

        def visit(object, collector = nil)
          dispatch_method = dispatch[object.class]
          if collector
            send dispatch_method, object, collector
          else
            send dispatch_method, object
          end
        rescue NoMethodError => e
          raise e if respond_to?(dispatch_method, true)
          superklass = object.class.ancestors.find { |klass|
            method_name = dispatch[klass]
            respond_to?(method_name, true)
          }
          raise(TypeError, "Cannot visit #{object.class}") unless superklass
          found_method = dispatch[superklass]
          dispatch[object.class] = found_method
          dispatch_method = found_method
          retry
        end
    end
  end
end
