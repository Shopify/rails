# :markup: markdown
# frozen_string_literal: true

require "active_support/weak_key_map"

module ActiveRecord
  # An association's writable foreign-key reference and query-only constraints,
  # oriented from the record holding the foreign key to the referenced record.
  class AssociationLink # :nodoc:
    EMPTY_FIXED_VALUES = {}.freeze
    private_constant :EMPTY_FIXED_VALUES

    attr_reader :reference, :reference_key, :constraints, :match

    # Attributes written alongside the foreign key, such as a polymorphic type.
    attr_reader :fixed_values

    def initialize(reference: nil, reference_key: reference&.reference_key, constraints: Key::Mapping.empty, fixed_values: EMPTY_FIXED_VALUES)
      @reference = reference
      @reference_key = reference_key
      @constraints = constraints
      @fixed_values = fixed_values.freeze
      @match = (constraints + reference).normalize if reference
      @hash = [reference, reference_key, constraints, @fixed_values].hash
      freeze
    end

    def ==(other)
      other.is_a?(AssociationLink) &&
        reference == other.reference &&
        reference_key == other.reference_key &&
        constraints == other.constraints &&
        fixed_values == other.fixed_values
    end
    alias_method :eql?, :==

    attr_reader :hash

    def reference_values(target_record)
      each_reference_value(target_record).to_h
    end

    def reference_needs_update?(reference_record, target_record)
      if reference_key.all? { |column| reference_record.has_attribute?(column) }
        return true if each_reference_key_value(target_record).any? { |column, value|
          reference_record.read_attribute(column) != value
        }
      end

      fixed_values.any? do |column, value|
        reference_record.has_attribute?(column) && reference_record.read_attribute(column) != value
      end
    end

    def write_reference(reference_record, target_record, force: true)
      each_reference_value(target_record) do |column, value|
        next if !force && reference_record.read_attribute(column) == value
        reference_record.write_attribute(column, value)
      end
    end

    private
      def each_reference_value(target_record, &)
        return enum_for(__method__, target_record) unless block_given?

        each_reference_key_value(target_record, &)
        fixed_values.each(&)
      end

      def each_reference_key_value(target_record)
        return enum_for(__method__, target_record) unless block_given?

        target_columns = reference.target_key.columns if target_record

        reference_key.each_with_index do |column, index|
          yield column, target_record&.read_attribute(target_columns[index])
        end
      end
  end

  # A link from an owner (origin) to its associated record (destination).
  # Keys stay as declared names; aliases are resolved on use against the
  # record or model being accessed.
  class AssociationRoute # :nodoc:
    EMPTY_FIXED_VALUES = {}.freeze
    EMPTY_KEY_PAIRS = [].freeze
    STRING_NORMALIZER = ActiveSupport::Ractors.shareable_lambda { |value| value&.to_s }.freeze
    private_constant :EMPTY_FIXED_VALUES, :EMPTY_KEY_PAIRS, :STRING_NORMALIZER

    class Cache < ActiveSupport::WeakKeyMap # :nodoc:
      NIL_KEY = Object.new.freeze
      private_constant :NIL_KEY

      def self.for(key)
        registry = ActiveSupport::Ractors.store_if_absent(:active_record_association_route_caches) { new }
        registry.fetch_or_store(key) { new }
      end

      def self.clear(key)
        ActiveSupport::Ractors[:active_record_association_route_caches]&.delete(key)
      end

      def fetch_or_store(key)
        super(key.nil? ? NIL_KEY : key)
      end
    end

    attr_reader :link

    def initialize(link:)
      @link = link
      initialize_keys
      @key_pairs = pairs_for(origin_key, destination_key)
      @reference_pairs = if link.constraints.empty?
        @key_pairs
      else
        pairs_for(reference_origin_key, reference_destination_key)
      end
      @hash = [self.class, link].hash
      freeze
    end

    def ==(other)
      other.class == self.class && link == other.link
    end
    alias_method :eql?, :==

    attr_reader :hash

    attr_reader :origin_key, :destination_key, :reference_origin_key, :reference_destination_key

    def predicate_accepts_bare_id?
      !origin_key.composite? && !reference_origin_key.composite?
    end

    def each_match(&block)
      @key_pairs.each(&block)
    end

    # Per-column conversions for comparing origin and destination key values.
    # A nil list or entry leaves the corresponding values unchanged.
    def match_normalizers(origin_class:, destination_class:)
      # Schema contexts are replaced on reload, so key by them to avoid
      # reusing conversions computed from outdated attribute types.
      cache = Cache.for(self)
      by_destination = cache.fetch_or_store(origin_class.schema_context) { Cache.new }
      by_destination.fetch_or_store(destination_class.schema_context) do
        build_match_normalizers(origin_class, destination_class)
      end
    end

    def key_values_match?(origin, destination)
      origin_normalizers, destination_normalizers = match_normalizers(origin_class: origin.class, destination_class: destination.class)
      origin_key.value_of(origin, origin_normalizers) == destination_key.value_of(destination, destination_normalizers)
    end

    def each_matching_origin(origins, destination)
      return enum_for(__method__, origins, destination) unless block_given?

      # The destination's conversion depends on the owner's attribute types, so
      # cache its converted value separately for each owner class.
      comparisons_by_class = {}
      origins.each do |origin|
        origin_normalizers, destination_value = comparisons_by_class[origin.class] ||= begin
          origin_normalizers, destination_normalizers = match_normalizers(origin_class: origin.class, destination_class: destination.class)
          [origin_normalizers, destination_key.value_of(destination, destination_normalizers)]
        end

        yield origin if origin_key.value_of(origin, origin_normalizers) == destination_value
      end
    end

    def origin_reference_complete?(origin)
      reference_origin_key.all? { |column| !origin.read_attribute(column).nil? }
    end

    def reference_needs_update?(origin, destination)
      @link.reference_needs_update?(origin, destination)
    end

    def each_reference(&block)
      @reference_pairs.each(&block)
    end

    def each_constraint(&block)
      @constraint_pairs.each(&block)
    end

    def origin_fixed_values
      @link.fixed_values
    end

    def destination_fixed_values
      EMPTY_FIXED_VALUES
    end

    def write(origin, destination, force: true)
      @link.write_reference(origin, destination, force: force)
    end

    private
      def initialize_keys
        @origin_key = link.match&.reference_key
        @destination_key = link.match&.target_key
        @reference_origin_key = link.reference_key
        @reference_destination_key = link.reference&.target_key
        @constraint_pairs = link.constraints.empty? ? EMPTY_KEY_PAIRS : pairs_for(link.constraints.reference_key, link.constraints.target_key)
      end

      def build_match_normalizers(origin_class, destination_class)
        origin_normalizers = destination_normalizers = nil
        each_match.with_index do |(origin_column, destination_column), index|
          origin_type = origin_class.type_for_attribute(origin_column)
          destination_type = destination_class.type_for_attribute(destination_column)
          origin_normalizer, destination_normalizer = normalizers_for_types(origin_type, destination_type)

          if origin_normalizer
            (origin_normalizers ||= Array.new(@key_pairs.length))[index] = origin_normalizer
          end
          if destination_normalizer
            (destination_normalizers ||= Array.new(@key_pairs.length))[index] = destination_normalizer
          end
        end
        [origin_normalizers&.freeze, destination_normalizers&.freeze].freeze
      end

      def normalizers_for_types(origin_type, destination_type)
        unless origin_type.type == destination_type.type
          [STRING_NORMALIZER, STRING_NORMALIZER]
        end
      end

      def pairs_for(origin_key, destination_key)
        origin_key.zip(destination_key).map!(&:freeze).freeze if origin_key && destination_key
      end
  end

  class AssociationRoute::Reverse < AssociationRoute # :nodoc:
    def reference_needs_update?(origin, destination)
      @link.reference_needs_update?(destination, origin)
    end

    def origin_fixed_values
      EMPTY_FIXED_VALUES
    end

    def destination_fixed_values
      @link.fixed_values
    end

    def write(origin, destination, force: true)
      @link.write_reference(destination, origin, force: force)
    end

    # The attributes #write would assign to a destination, for building one.
    def destination_attributes(origin)
      @link.reference_values(origin)
    end

    private
      def initialize_keys
        @origin_key = link.match&.target_key
        @destination_key = link.match&.reference_key
        @reference_origin_key = link.reference&.target_key
        @reference_destination_key = link.reference_key
        @constraint_pairs = link.constraints.empty? ? EMPTY_KEY_PAIRS : pairs_for(link.constraints.target_key, link.constraints.reference_key)
      end
  end
end
