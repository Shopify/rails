# frozen_string_literal: true

module ActiveRecord
  # Caches a query's compiled form and bind layout to avoid rebuilding its
  # Arel AST on each execution.
  #
  # Create a statement cache from a relation:
  #
  #   cache = StatementCache.create(Book.lease_connection) do
  #     Book.where(name: "my book").where("author_id > 3")
  #   end
  #
  # +execute+ binds the supplied values and runs the cached query:
  #
  #   cache.execute([], Book.lease_connection)
  #
  # For values that vary between executions, use +bind+ in the create block:
  #
  #   cache = StatementCache.create(Book.lease_connection) do |params|
  #     Book.where(name: params.bind)
  #   end
  #
  # Supply the bind values as the first argument to +execute+:
  #
  #   cache.execute(["my book"], Book.lease_connection)
  #
  # Positional inputs follow the order of calls to +bind+, independently of
  # their order or number of appearances in the SQL. Inputs can also have keys:
  #
  #   cache = StatementCache.create(Book.lease_connection) do |params|
  #     Book.where(name: params.bind(:title))
  #   end
  #   cache.execute({ title: "my book" }, Book.lease_connection)
  #
  # Keys are resolved with #[] on the execution input; a Method or Proc can
  # supply values without constructing a Hash.
  class StatementCache # :nodoc:
    class Substitute # :nodoc:
      attr_reader :key

      def initialize(key = nil)
        @key = key
      end
    end

    class Query # :nodoc:
      attr_reader :retryable

      def initialize(sql, retryable:)
        @sql = sql
        @retryable = retryable
      end

      def sql_for(binds, connection)
        @sql
      end
    end

    class PartialQuery < Query # :nodoc:
      def initialize(values, retryable:)
        @values = values
        @indexes = values.each_with_index.find_all { |thing, i|
          Substitute === thing
        }.map(&:last)
        @retryable = retryable
      end

      def sql_for(binds, connection)
        val = @values.dup
        @indexes.each do |i|
          value = binds.shift
          if ActiveModel::Attribute === value
            value = value.value_for_database
          end
          val[i] = connection.quote(value)
        end
        val.join
      end
    end

    class PartialQueryCollector
      attr_accessor :preparable, :retryable

      def initialize
        @parts = []
        @binds = []
      end

      def <<(str)
        @parts << str
        self
      end

      def add_bind(obj, &)
        @binds << obj
        @parts << Substitute.new
        self
      end

      def add_binds(binds, proc_for_binds = nil, &)
        @binds.concat proc_for_binds ? binds.map(&proc_for_binds) : binds
        binds.size.times do |i|
          @parts << ", " unless i == 0
          @parts << Substitute.new
        end
        self
      end

      def value
        [@parts, @binds]
      end
    end

    def self.query(...)
      Query.new(...)
    end

    def self.partial_query(...)
      PartialQuery.new(...)
    end

    def self.partial_query_collector
      PartialQueryCollector.new
    end

    class Params # :nodoc:
      def initialize
        @index = 0
      end

      def bind(key = @index)
        @index += 1
        Substitute.new(key)
      end
    end

    class BindMap # :nodoc:
      def initialize(bound_attributes)
        @indexes = []
        @bound_attributes = bound_attributes

        bound_attributes.each_with_index do |attr, i|
          if ActiveModel::Attribute === attr && Substitute === attr.value
            @indexes << [i, attr.value.key]
          end
        end
      end

      def bind(values)
        bas = @bound_attributes.dup
        @indexes.each { |offset, key| bas[offset] = bas[offset].with_cast_value(values[key]) }
        bas
      end
    end

    def self.create(connection, callable = nil, &block)
      relation = (callable || block).call Params.new
      query_builder, binds = connection.cacheable_query(self, relation.arel)
      bind_map = BindMap.new(binds)
      new(query_builder, bind_map, relation.model)
    end

    def initialize(query_builder, bind_map, model)
      @query_builder = query_builder
      @bind_map = bind_map
      @model = model
    end

    def execute(params, connection, async: false, &block)
      bind_values = @bind_map.bind params
      sql = @query_builder.sql_for bind_values, connection

      if async
        @model.async_find_by_sql(sql, bind_values, preparable: true, allow_retry: @query_builder.retryable, &block)
      else
        @model.find_by_sql(sql, bind_values, preparable: true, allow_retry: @query_builder.retryable, &block)
      end
    rescue ::RangeError
      async ? Promise::Complete.new([]) : []
    end

    def self.unsupported_value?(value)
      case value
      when NilClass, Array, Range, Hash, Relation, Base then true
      end
    end
  end
end
