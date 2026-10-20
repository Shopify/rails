# frozen_string_literal: true

# :markup: markdown

require "active_support/weak_key_map"

module ActiveRecord
  module ModelSchema
    # SchemaContext owns all schema-derived state for a model: columns,
    # attribute types, column defaults, and query constraints.
    class SchemaContext # :nodoc:
      # Keep column metadata separate so the context is shareable before columns load.
      # Each Ractor caches a reference to the same immutable SchemaData.
      class SchemaData # :nodoc:
        attr_reader :columns_hash, :columns, :column_names, :content_columns,
          :query_constraints_list, :composite_query_constraints_list, :composite_query_constraints_definition,
          :timestamp_attributes_for_create_in_model, :timestamp_attributes_for_update_in_model,
          :all_timestamp_attributes_in_model

        attr_accessor :attributes

        def initialize(context)
          model_class = context.model_class
          unless context.table_name
            raise ActiveRecord::TableNotSpecified, "#{model_class} has no table configured. Set one with #{model_class}.table_name="
          end

          columns_hash = model_class.connection_pool.schema_cache.columns_hash(context.table_name)
          if context.only_columns.present?
            columns_hash = columns_hash.slice(*context.only_columns)
          elsif context.ignored_columns.present?
            columns_hash = columns_hash.except(*context.ignored_columns)
          end
          @columns_hash = columns_hash.freeze
          @columns = @columns_hash.values.freeze
          @column_names = @columns.map(&:name).freeze

          primary_key = context.primary_key
          @query_constraints_list = context.send(:derive_query_constraints_list, primary_key)
          @composite_query_constraints_list = (@query_constraints_list || Array(primary_key)).freeze
          @composite_query_constraints_definition = ActiveRecord::Key.for(@composite_query_constraints_list)
          @content_columns = @columns.reject do |column|
            Array(primary_key).include?(column.name) ||
              column.name == context.inheritance_column ||
              column.name.end_with?("_id", "_count")
          end.freeze

          @timestamp_attributes_for_create_in_model = (model_class.timestamp_attributes_for_create & @column_names).freeze
          @timestamp_attributes_for_update_in_model = (model_class.timestamp_attributes_for_update & @column_names).freeze
          @all_timestamp_attributes_in_model = (@timestamp_attributes_for_create_in_model + @timestamp_attributes_for_update_in_model).freeze
        end
      end

      # The attributes that records loaded from the database fall back to
      # defaults for when the row doesn't have them: the primary key, and
      # attributes that aren't database columns. Other missing columns stay
      # uninitialized.
      class DatabaseDefaultKeys # :nodoc:
        def initialize(primary_key, columns_hash)
          @primary_key = primary_key
          @columns_hash = columns_hash
        end

        def include?(name)
          @primary_key.include?(name) || !@columns_hash.key?(name)
        end
      end

      # Attributes owns a model's attribute-derived state: attribute
      # defaults, attribute types, and column defaults.
      class Attributes # :nodoc:
        attr_reader :defaults, :types, :builder

        # Built up front, since shareable instances are frozen along with
        # the column metadata.
        def initialize(context, defaults)
          @defaults = defaults
          @types = defaults.cast_types.tap do |hash|
            hash.default = ActiveModel::Type.default_value
          end
          default_keys = DatabaseDefaultKeys.new(context.model_class.primary_key_definition, context.columns_hash)
          @builder = ActiveModel::AttributeSet::Builder.new(@types, defaults, default_keys)
          @column_defaults = defaults.to_hash.freeze if defaults.read_only?
        end

        # Lazy otherwise, since evaluating them calls proc defaults.
        def column_defaults
          @column_defaults ||= defaults.deep_dup.to_hash.freeze
        end
      end

      attr_reader :model_class, :only_columns, :ignored_columns,
        :inheritance_column, :query_constraints_definition

      def initialize(model_class)
        @model_class = model_class
        @only_columns = model_class.only_columns
        @ignored_columns = model_class.ignored_columns
        @inheritance_column = model_class.inheritance_column
        @query_constraints_definition = model_class.query_constraints_definition
      end

      def attributes
        # Share read-only attributes with the column metadata. Otherwise each
        # Ractor builds its own attributes.
        schema_data.attributes || initialize_attributes
      end

      def columns_hash
        schema_data.columns_hash
      end

      def columns
        schema_data.columns
      end

      def column_names
        schema_data.column_names
      end

      def content_columns
        schema_data.content_columns
      end

      def query_constraints_list
        schema_data.query_constraints_list
      end

      def composite_query_constraints_list
        schema_data.composite_query_constraints_list
      end

      def composite_query_constraints_definition
        schema_data.composite_query_constraints_definition
      end

      def timestamp_attributes_for_create_in_model
        schema_data.timestamp_attributes_for_create_in_model
      end

      def timestamp_attributes_for_update_in_model
        schema_data.timestamp_attributes_for_update_in_model
      end

      def all_timestamp_attributes_in_model
        schema_data.all_timestamp_attributes_in_model
      end

      def table_name
        model_class.table_name
      end

      def primary_key
        model_class.primary_key
      end

      def has_query_constraints?
        !!query_constraints_definition
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
        if data = schema_data_cache[self]
          return data.frozen?
        end

        ActiveSupport::Ractors.on_main(self) { !!schema_data_cache[self]&.frozen? }
      end

      # The model's columns as attributes, with its attribute declarations
      # applied. Read only unless some default can't be frozen.
      def build_default_attributes # :nodoc:
        attributes = columns_hash.transform_values do |column|
          ActiveModel::Attribute.from_database(column.name, column.default, model_class.type_for_column(column))
        end
        model_class.apply_pending_attribute_modifications(attributes)

        if attributes.each_value.all?(&:freezable?)
          attributes.each_value(&:freeze)
          ActiveModel::ReadOnlyAttributeSet.new(attributes.freeze)
        else
          ActiveModel::AttributeSet.new(attributes)
        end
      end

      def load_schema!
        # Attribute initialization can read column metadata recursively. Other
        # callers acquire the model's schema monitor until this data is frozen.
        data = schema_data_cache[self] = SchemaData.new(self)
        model_class.make_pending_attribute_modifications_shareable
        attributes = Attributes.new(self, build_default_attributes)
        if attributes.defaults.read_only? && ActiveSupport::Ractors.shareable?(attributes.defaults)
          data.attributes = attributes
        else
          attributes_cache[self] = attributes
        end
        ActiveSupport::Ractors.make_shareable(data.freeze)
      end

      def clear_schema # :nodoc:
        schema_data_cache.delete(self)
        attributes_cache.delete(self)
      end

      private
        def schema_data
          if (data = schema_data_cache[self]) && data.frozen?
            return data
          end

          data = ActiveSupport::Ractors.on_main(self) do
            model_class.load_schema(self)
            schema_data_cache[self]
          end
          schema_data_cache[self] = data
        end

        def initialize_attributes
          attributes_cache[self] ||= Attributes.new(self, build_default_attributes)
        end

        def schema_data_cache
          ActiveSupport::Ractors.store_if_absent(:active_record_schema_data) { ActiveSupport::WeakKeyMap.new }
        end

        def attributes_cache
          ActiveSupport::Ractors.store_if_absent(:active_record_schema_attributes) { ActiveSupport::WeakKeyMap.new }
        end

        def derive_query_constraints_list(primary_key)
          return query_constraints_definition if query_constraints_definition

          if model_class.base_class? || primary_key != model_class.base_class.primary_key
            primary_key if primary_key.is_a?(Array)
          else
            model_class.base_class.query_constraints_definition || (primary_key if primary_key.is_a?(Array))
          end
        end
    end
  end
end
