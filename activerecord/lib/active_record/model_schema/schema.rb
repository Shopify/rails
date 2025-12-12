# frozen_string_literal: true

require "monitor"

module ActiveRecord
  module ModelSchema
    # Encapsulates all schema-context-dependent state for a model.
    # Each model class maintains a hash of Schema instances, keyed by schema context key.
    #
    # Schema context keys group connections sharing a schema shape - the same adapter,
    # column types, SQL dialect, etc. Multiple pools (read replicas, shards) can share
    # the same key, meaning they share cached schema information.
    class Schema
      attr_reader :model_class, :context_key

      def initialize(model_class, context_key)
        @model_class = model_class
        @context_key = context_key
        @schema_loaded = false
        @load_schema_monitor = Monitor.new

        # Schema-context-dependent state
        @columns_hash = nil
        @columns = nil
        @column_names = nil
        @default_attributes = nil
        @attribute_types = nil
        @attributes_builder = nil
        @column_defaults = nil
        @_returning_columns_for_insert = nil
        @sequence_name = nil
        @table_name = nil
        @arel_table = nil
        @predicate_builder = nil
        @find_by_statement_cache = nil
        @content_columns = nil
        @symbol_column_to_string_name_hash = nil
        @primary_key = nil
        @composite_primary_key = nil
      end

      # Returns the columns hash for this schema context
      def columns_hash
        load_schema unless @columns_hash
        @columns_hash
      end

      # Returns array of column objects
      def columns
        @columns ||= columns_hash.values.freeze
      end

      # Returns array of column names as strings
      def column_names
        @column_names ||= columns.map(&:name).freeze
      end

      # Returns the Arel table for this schema context
      def arel_table
        @arel_table ||= Arel::Table.new(table_name, klass: model_class)
      end

      # Returns the predicate builder for this schema context
      def predicate_builder
        @predicate_builder ||= PredicateBuilder.new(TableMetadata.new(model_class, arel_table))
      end

      # Returns the table name for this schema context
      # For now, delegates to the model class
      def table_name
        model_class.table_name
      end

      # Returns the sequence name for this schema context
      def sequence_name
        @sequence_name ||= begin
          model_class.with_connection do |conn|
            conn.default_sequence_name(table_name, primary_key)
          end
        end
      end

      # Returns the primary key column(s) for this schema context
      # For now, delegates to the model class
      # In a full implementation, this would be per-context
      def primary_key
        model_class.primary_key
      end

      # Returns whether this schema context has a composite primary key
      def composite_primary_key?
        model_class.composite_primary_key?
      end

      # Returns the default attributes for this schema context
      # This is complex because it needs to integrate with the model's attribute system
      # which handles pending attribute modifications (custom types, defaults, etc.)
      # So we delegate back to the model class which has the full implementation
      def attributes_builder
        # Note: This will call back to the model class's _default_attributes
        # which will call columns_hash, which delegates back to us
        # This ensures pending attribute modifications are properly applied
        @attributes_builder ||= begin
          defaults = model_class._default_attributes.except(*(column_names - [primary_key].flatten))
          ActiveModel::AttributeSet::Builder.new(attribute_types, defaults)
        end
      end

      # Returns column defaults hash
      def column_defaults
        load_schema
        @column_defaults ||= model_class._default_attributes.deep_dup.to_hash.freeze
      end

      # Returns columns for insert returning
      def _returning_columns_for_insert(connection)
        @_returning_columns_for_insert ||= begin
          auto_populated_columns = columns.filter_map do |c|
            c.name if connection.return_value_after_insert?(c)
          end

          auto_populated_columns.empty? ? Array(primary_key) : auto_populated_columns
        end
      end

      # Returns attribute types hash
      def attribute_types
        @attribute_types ||= model_class._default_attributes.cast_types
      end

      # Returns content columns (non-meta columns)
      def content_columns
        @content_columns ||= columns.reject do |c|
          pk = primary_key.is_a?(Array) ? primary_key : [primary_key]
          pk.include?(c.name) ||
          c.name == model_class.inheritance_column ||
          c.name.end_with?("_id", "_count")
        end.freeze
      end

      # Symbol to string column name mapping
      def symbol_column_to_string(name_symbol)
        @symbol_column_to_string_name_hash ||= column_names.index_by(&:to_sym)
        @symbol_column_to_string_name_hash[name_symbol]
      end

      # Returns the column object for a named attribute
      def column_for_attribute(name)
        name = name.to_s
        columns_hash.fetch(name) do
          ConnectionAdapters::NullColumn.new(name)
        end
      end

      # Reset all cached schema state
      def reload_schema_from_cache
        @_returning_columns_for_insert = nil
        @arel_table = nil
        @column_names = nil
        @symbol_column_to_string_name_hash = nil
        @content_columns = nil
        @column_defaults = nil
        @attributes_builder = nil
        @columns = nil
        @columns_hash = nil
        @schema_loaded = false
        @attribute_names = nil
        @attribute_types = nil
        @primary_key = nil
        @composite_primary_key = nil
      end

      # Load schema information from the schema cache
      def load_schema
        return if schema_loaded?
        @load_schema_monitor.synchronize do
          return if schema_loaded?

          load_schema!
          @schema_loaded = true
        rescue
          reload_schema_from_cache
          raise
        end
      end

      private
        def schema_loaded?
          @schema_loaded
        end

        def load_schema!
          unless table_name
            raise ActiveRecord::TableNotSpecified, "#{model_class} has no table configured. Set one with #{model_class}.table_name="
          end

          columns_hash = schema_cache.columns_hash(table_name)
          if model_class.only_columns.present?
            columns_hash = columns_hash.slice(*model_class.only_columns)
          elsif model_class.ignored_columns.present?
            columns_hash = columns_hash.except(*model_class.ignored_columns)
          end
          @columns_hash = columns_hash.freeze

          # Precompute default attributes to cache DB-dependent attribute types
          # This calls back to the model class which handles pending modifications
          model_class._default_attributes
        end

        def schema_cache
          connection_pool.schema_cache
        end

        def connection_pool
          model_class.connection_pool
        end

        def connection
          model_class.lease_connection
        end
    end
  end
end
