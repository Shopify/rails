# frozen_string_literal: true

module ActiveRecord
  module ModelSchema
    # Encapsulates schema-derived state for a model.
    #
    # Rails uses a single default schema context per model. Applications that
    # maintain multiple schema shapes for the same model can override the model's
    # schema_context selector and build additional contexts.
    class SchemaContext # :nodoc:
      attr_reader :model_class, :context_key

      def initialize(model_class, context_key)
        @model_class = model_class
        @context_key = context_key

        reload_schema_from_cache
      end

      def attributes_builder
        @attributes_builder ||= begin
          defaults = _default_attributes.except(*(column_names - Array(primary_key)))
          ActiveModel::AttributeSet::Builder.new(attribute_types, defaults)
        end
      end

      def columns_hash
        model_class.load_schema unless @columns_hash
        @columns_hash
      end

      def columns
        @columns ||= columns_hash.values.freeze
      end

      def _returning_columns_for_insert(connection)
        @_returning_columns_for_insert ||= begin
          auto_populated_columns = columns.filter_map do |c|
            c.name if connection.return_value_after_insert?(c)
          end

          auto_populated_columns.empty? ? Array(primary_key) : auto_populated_columns
        end
      end

      def column_defaults
        model_class.load_schema
        @column_defaults ||= _default_attributes.deep_dup.to_hash.freeze
      end

      def column_names
        @column_names ||= columns.map(&:name).freeze
      end

      def symbol_column_to_string(name_symbol)
        @symbol_column_to_string_name_hash ||= column_names.index_by(&:to_sym)
        @symbol_column_to_string_name_hash[name_symbol]
      end

      def content_columns
        @content_columns ||= columns.reject do |c|
          Array(primary_key).include?(c.name) ||
            c.name == model_class.inheritance_column ||
            c.name.end_with?("_id", "_count")
        end.freeze
      end

      def _default_attributes
        @default_attributes ||= begin
          attributes_hash = columns_hash.transform_values do |column|
            ActiveModel::Attribute.from_database(
              column.name,
              column.default,
              model_class.send(:type_for_column, column)
            )
          end

          attribute_set = ActiveModel::AttributeSet.new(attributes_hash)
          model_class.send(:apply_pending_attribute_modifications, attribute_set)
          attribute_set
        end
      end

      def attribute_types
        @attribute_types ||= _default_attributes.cast_types.tap do |hash|
          hash.default = ActiveModel::Type.default_value
        end
      end

      def load_schema!
        return if @schema_loaded

        unless table_name
          raise ActiveRecord::TableNotSpecified,
            "#{model_class} has no table configured. Set one with #{model_class}.table_name="
        end

        columns_hash = model_class.schema_cache.columns_hash(table_name)
        if model_class.only_columns.present?
          columns_hash = columns_hash.slice(*model_class.only_columns)
        elsif model_class.ignored_columns.present?
          columns_hash = columns_hash.except(*model_class.ignored_columns)
        end
        @columns_hash = columns_hash.freeze

        _default_attributes

        @schema_loaded = true
      end

      def schema_loaded?
        @schema_loaded
      end

      def reload_schema_from_cache
        @_returning_columns_for_insert = nil
        @symbol_column_to_string_name_hash = nil
        @content_columns = nil
        @column_defaults = nil
        @column_names = nil
        @columns = nil
        @columns_hash = nil
        @schema_loaded = false
        @attributes_builder = nil
        @attribute_types = nil
        @default_attributes = nil
      end

      private
        def primary_key
          model_class.primary_key
        end

        def table_name
          model_class.table_name
        end
    end
  end
end
