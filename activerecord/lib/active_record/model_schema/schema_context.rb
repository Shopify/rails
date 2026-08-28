# frozen_string_literal: true

# :markup: markdown

module ActiveRecord
  module ModelSchema
    # SchemaContext owns the column-derived state for a model: the columns
    # themselves, and the caches keyed off them.
    class SchemaContext # :nodoc:
      attr_reader :model_class, :columns_hash, :columns, :column_names,
                  :content_columns

      def initialize(model_class)
        @model_class = model_class
        @schema_loaded = false
      end

      def table_name
        model_class.table_name
      end

      def primary_key
        model_class.primary_key
      end

      def _returning_columns_for_insert(connection)
        auto_populated_columns = columns.filter_map do |c|
          -c.name if connection.return_value_after_insert?(c)
        end

        (auto_populated_columns.empty? ? Array(primary_key) : auto_populated_columns).freeze
      end

      def _returning_columns_for_update(connection)
        columns.filter_map do |c|
          c.name if connection.return_value_after_update?(c)
        end.freeze
      end

      def cached_find_by_statement(connection, key, &block) # :nodoc:
        cache = find_by_statement_cache[connection.prepared_statements]
        cache.compute_if_absent(key) { StatementCache.create(connection, &block) }
      end

      def initialize_find_by_cache # :nodoc:
        ActiveSupport::Ractors[model_class.find_by_statement_cache_key] = { true => Concurrent::Map.new, false => Concurrent::Map.new }
      end

      def find_by_statement_cache # :nodoc:
        ActiveSupport::Ractors[model_class.find_by_statement_cache_key] || initialize_find_by_cache
      end

      def schema_loaded?
        @schema_loaded
      end

      def freeze
        load_schema!
        super
      end

      def load_schema!
        return if @schema_loaded

        unless table_name
          raise ActiveRecord::TableNotSpecified, "#{model_class} has no table configured. Set one with #{model_class}.table_name="
        end

        columns_hash = model_class.connection_pool.schema_cache.columns_hash(table_name)
        if model_class.only_columns.present?
          columns_hash = columns_hash.slice(*model_class.only_columns)
        elsif model_class.ignored_columns.present?
          columns_hash = columns_hash.except(*model_class.ignored_columns)
        end
        @columns_hash = columns_hash.freeze

        @columns = @columns_hash.values.freeze
        @column_names = @columns.map(&:name).freeze

        @content_columns = @columns.reject do |c|
          Array(primary_key).include?(c.name) ||
          c.name == model_class.inheritance_column ||
          c.name.end_with?("_id", "_count")
        end.freeze

        @schema_loaded = true
      end
    end
  end
end
