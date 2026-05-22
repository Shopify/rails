# frozen_string_literal: true

module ActiveRecord
  module Type
    class TypeMap # :nodoc:
      # Entries stored in @mapping. All three are tiny frozen value
      # objects so the whole TypeMap can be made shareable across
      # Ractors without capturing self in a Proc.
      ValueEntry = Struct.new(:value) do
        def fetch(_lookup_key) = value
      end

      # Holds the TypeMap the alias was registered on so the deferred
      # lookup goes back through the right map's chain.
      AliasEntry = Struct.new(:target_key, :map) do
        def fetch(lookup_key)
          metadata = lookup_key[/\(.*\)/, 0]
          map.lookup("#{target_key}#{metadata}")
        end
      end

      BlockEntry = Struct.new(:block) do
        def fetch(lookup_key)
          block.call(lookup_key).freeze
        end
      end

      private_constant :ValueEntry, :AliasEntry, :BlockEntry

      def initialize(parent = nil)
        @mapping = {}
        @parent = parent
      end

      def lookup(lookup_key)
        fetch(lookup_key) { Type.default_value }
      end

      def fetch(lookup_key, &block)
        cache = cache_for_ractor
        cache.fetch(lookup_key) do
          cache[lookup_key] = perform_fetch(lookup_key, &block)
        end
      end

      def register_type(key, value = nil, &block)
        raise ::ArgumentError unless value || block

        @mapping[key] =
          if block
            BlockEntry.new(block).freeze
          else
            ValueEntry.new(value).freeze
          end
      end

      def alias_type(key, target_key)
        @mapping[key] = AliasEntry.new(target_key.dup.freeze, self).freeze
      end

      # Freeze @mapping when the TypeMap is frozen. Each entry is
      # already a frozen Struct of shareable parts, except for
      # BlockEntry which holds a user-supplied Proc whose self may
      # only become shareable once we've frozen ourselves. After
      # freezing, walk @mapping and make any non-shareable block
      # entries shareable so the TypeMap is deeply shareable.
      def freeze
        # Memoize the per-Ractor cache key before the object is
        # frozen so cache_for_ractor doesn't try to write the ivar.
        ractor_cache_key
        super
        @mapping.each_value do |entry|
          Ractor.make_shareable(entry) unless Ractor.shareable?(entry)
        end
        @mapping.freeze
        self
      end

      protected
        def perform_fetch(lookup_key, &block)
          matching_pair = @mapping.reverse_each.detect do |key, _|
            key === lookup_key
          end

          if matching_pair
            matching_pair.last.fetch(lookup_key)
          elsif @parent
            @parent.perform_fetch(lookup_key, &block)
          else
            yield lookup_key
          end
        end

      private
        # Per-Ractor lookup cache. Each Ractor owns its own Hash so
        # there's no cross-Ractor mutation. The TypeMap object_id is
        # stable for the life of the process and identifies this
        # map's bucket within the current Ractor's local storage.
        def cache_for_ractor
          Ractor.current[ractor_cache_key] ||= {}
        end

        def ractor_cache_key
          @ractor_cache_key ||= :"__type_map_cache_#{object_id}"
        end
    end
  end
end
