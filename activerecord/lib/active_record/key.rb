# frozen_string_literal: true

module ActiveRecord
  class Key # :nodoc:
    include Enumerable

    def self.for(name)
      key = case name
      when Array
        Composite.new(name)
      when nil, false
        None.new
      else
        Single.new(name)
      end

      key.freeze
    end

    attr_reader :name, :columns

    def present?
      !@columns.empty?
    end

    def each(&block)
      @columns.each(&block)
    end

    # Pairs this key's columns with another key's columns.
    def zip(other, &)
      @columns.zip(other.columns, &)
    end

    def length
      @columns.length
    end
    alias_method :size, :length

    def to_a
      @columns
    end

    def to_s
      @name.to_s
    end

    def ==(other)
      other.is_a?(Key) && name == other.name
    end
    alias_method :eql?, :==

    def hash
      name.hash
    end

    def composite?
      raise NotImplementedError
    end

    def where_hash(values)
      raise NotImplementedError
    end

    def arel_columns(table)
      raise NotImplementedError
    end

    def cast(values, model)
      raise NotImplementedError
    end

    # Yields column names and returns a scalar or tuple according to the key's
    # shape. Unlike Enumerable#map, a scalar result is not wrapped in an Array.
    def map_value
      raise NotImplementedError
    end

    # Returns a key of the same shape with transformed column names.
    def transform(&)
      self.class.new(map_value(&)).freeze
    end

    # Reads attributes with optional per-column normalizers. A nil list or entry
    # leaves the corresponding values unchanged.
    def value_of(record, normalizers = nil)
      raise NotImplementedError
    end

    def expects_multiple_ids?(value)
      raise NotImplementedError
    end

    def inferred_id
      raise NotImplementedError
    end

    def where_clauses(values)
      raise NotImplementedError
    end

    class Single < Key # :nodoc:
      def initialize(name)
        @name = -name.to_s
        @columns = [@name].freeze
      end

      def composite?
        false
      end

      def where_hash(values)
        { @name => values }
      end

      def arel_columns(table)
        table[@name]
      end

      def cast(value, model)
        model.type_for_attribute(@name).cast(value)
      end

      def map_value
        return enum_for(:map_value) unless block_given?
        yield @name
      end

      def value_of(record, normalizers = nil)
        value = record.read_attribute(@name)
        normalizer = normalizers&.first
        normalizer ? normalizer.call(value) : value
      end

      def expects_multiple_ids?(value)
        value.is_a?(Array)
      end

      # Only composite keys have a single id to infer.
      def inferred_id
        nil
      end

      def where_clauses(values)
        [where_hash(values)]
      end
    end

    class Composite < Key # :nodoc:
      def initialize(columns)
        @columns = columns.map { |column| -column.to_s }.freeze
        @name = @columns
      end

      def composite?
        true
      end

      def where_hash(values)
        @columns.zip(values).to_h
      end

      def arel_columns(table)
        @columns.map { |column| table[column] }
      end

      def cast(values, model)
        casted = []
        @columns.zip(values) do |column, value|
          casted << model.type_for_attribute(column).cast(value)
        end
        casted
      end

      def map_value(&)
        @columns.map(&)
      end

      def value_of(record, normalizers = nil)
        if normalizers
          Array.new(@columns.length) do |index|
            value = record.read_attribute(@columns[index])
            normalizer = normalizers[index]
            normalizer ? normalizer.call(value) : value
          end
        else
          @columns.map { |column| record.read_attribute(column) }
        end
      end

      # A single composite id is itself an Array, so several ids are an Array of
      # Arrays. An empty Array carries no composite id, so it is treated as an
      # empty set of ids.
      def expects_multiple_ids?(value)
        value.is_a?(Array) && (value.empty? || value.first.is_a?(Array))
      end

      # When a composite key has the conventional [tenant_key, "id"] shape,
      # associations join on "id" alone; otherwise the whole key is used.
      def inferred_id
        @columns.include?("id") ? "id" : @name
      end

      def where_clauses(values)
        values.map { |set| where_hash(set) }
      end
    end

    class None < Single # :nodoc:
      def initialize
        @name = nil
        @columns = [].freeze
      end

      def map_value
        return enum_for(:map_value) unless block_given?
        nil
      end

      def transform
        self
      end
    end

    # An ordered correspondence between two database keys.
    class Mapping # :nodoc:
      include Enumerable

      attr_reader :reference_key, :target_key

      def self.empty
        EMPTY
      end

      def initialize(reference_key:, target_key:)
        @reference_key = reference_key
        @target_key = target_key
        if @reference_key.length != @target_key.length
          raise ArgumentError, "Key mappings must have the same number of columns"
        end
        @pairs = @reference_key.zip(@target_key).map!(&:freeze).freeze
        @hash = [@reference_key, @target_key].hash
        freeze
      end

      def each(&block)
        @pairs.each(&block)
      end

      def empty?
        @pairs.empty?
      end

      # Canonicalizes one-column keys to scalar shape without changing this mapping.
      def normalize
        return self unless @reference_key.length == 1 && (@reference_key.composite? || @target_key.composite?)

        self.class.new(
          reference_key: @reference_key.composite? ? Key.for(@reference_key.columns.first) : @reference_key,
          target_key: @target_key.composite? ? Key.for(@target_key.columns.first) : @target_key
        )
      end

      def +(other)
        return other if empty?
        return self if other.empty?

        self.class.new(
          reference_key: Key.for([*@reference_key, *other.reference_key]),
          target_key: Key.for([*@target_key, *other.target_key])
        )
      end

      def ==(other)
        other.is_a?(Mapping) &&
          reference_key == other.reference_key &&
          target_key == other.target_key
      end
      alias_method :eql?, :==

      attr_reader :hash

      EMPTY = begin
        key = Key.for(nil)
        new(reference_key: key, target_key: key)
      end
      private_constant :EMPTY
    end
  end
end
