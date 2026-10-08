# frozen_string_literal: true

# :markup: markdown

module ActiveRecord
  module ModelSchema
    # SchemaContext owns all schema-derived state for a model: table name,
    # primary key, columns, attribute types, column defaults, and query constraints.
    class SchemaContext # :nodoc:
      # Attributes owns a model's attribute-derived state: attribute
      # defaults, attribute types, and column defaults.
      class Attributes # :nodoc:
        attr_reader :context, :defaults

        def initialize(context, attribute_set)
          context.model_class.apply_pending_attribute_modifications(attribute_set)

          @defaults = attribute_set
          @context = context
        end

        def types
          @types ||= defaults.cast_types.tap do |hash|
            hash.default = ActiveModel::Type.default_value
          end
        end

        def builder
          primary_key_defaults = defaults.except(*(context.column_names - Array(context.primary_key)))
          ActiveModel::AttributeSet::Builder.new(types, primary_key_defaults)
        end

        def column_defaults
          @column_defaults ||= defaults.deep_dup.to_hash.freeze
        end
      end

      attr_reader :model_class

      def initialize(model_class)
        @model_class = model_class
        @table_name_definition = model_class.table_name_definition
        @primary_key_default = model_class._primary_key_definition
        @primary_key_declared = model_class.primary_key_declared?
        @schema_loaded = false
        @attributes_key = :"active_record_schema_attributes_#{object_id}"
      end

      def attributes
        load_schema
        initialize_attributes
      end

      def columns_hash
        load_schema
        @columns_hash
      end

      def columns
        load_schema
        @columns
      end

      def column_names
        load_schema
        @column_names
      end

      def content_columns
        load_schema
        @content_columns
      end

      def query_constraints_list
        load_schema
        @query_constraints_list
      end

      def composite_query_constraints_list
        load_schema
        @composite_query_constraints_list
      end

      def timestamp_attributes_for_create_in_model
        load_schema
        @timestamp_attributes_for_create_in_model
      end

      def timestamp_attributes_for_update_in_model
        load_schema
        @timestamp_attributes_for_update_in_model
      end

      def all_timestamp_attributes_in_model
        load_schema
        @all_timestamp_attributes_in_model
      end

      def table_name
        return @table_name if defined?(@table_name)

        @table_name = if custom_table_name?
          model_class.table_name
        else
          default_table_name
        end
        @table_name = (@table_name && @table_name.to_s).freeze
      end

      def model_table_name_resolved?
        !!defined?(@default_table_name)
      end

      def model_table_name
        # A custom reader that calls super needs the default, not its own resolved override.
        custom_table_name? ? default_table_name : table_name
      end

      def inferred_table_name
        if model_class == Base
          nil
        elsif model_class.abstract_class?
          model_class.superclass.table_name
        elsif model_class.superclass.abstract_class?
          model_class.superclass.table_name || compute_table_name
        else
          compute_table_name
        end
      end

      def primary_key
        primary_key_definition.name
      end

      def primary_key_definition
        return @primary_key_definition if @primary_key_definition

        @primary_key_definition = if custom_primary_key?
          ActiveRecord::Key.for(model_class.primary_key)
        else
          default_primary_key_definition
        end
        model_class.include AttributeMethods::CompositePrimaryKey if @primary_key_definition.composite?
        @primary_key_definition
      end

      def model_primary_key
        # A custom reader that calls super needs the default, not its own resolved override.
        custom_primary_key? ? default_primary_key_definition.name : primary_key
      end

      def table_exists?
        model_class.schema_cache.data_source_exists?(table_name)
      end

      def get_primary_key(base_name)
        if base_name && model_class.primary_key_prefix_type == :table_name
          base_name.foreign_key(false)
        elsif base_name && model_class.primary_key_prefix_type == :table_name_with_underscore
          base_name.foreign_key
        elsif ActiveRecord::Base != model_class && table_exists?
          model_class.schema_cache.primary_keys(table_name)
        else
          "id"
        end
      end

      def has_query_constraints?
        !!query_constraints
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
        load_schema
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

      def attribute_set
        load_schema
        build_attribute_set
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

        primary_key = self.primary_key
        @query_constraints_list = query_constraints || derive_query_constraints_list(primary_key)
        @composite_query_constraints_list = (@query_constraints_list || Array(primary_key)).freeze

        @content_columns = @columns.reject do |c|
          Array(primary_key).include?(c.name) ||
          c.name == model_class.inheritance_column ||
          c.name.end_with?("_id", "_count")
        end.freeze

        @timestamp_attributes_for_create_in_model = (model_class.timestamp_attributes_for_create & @column_names).freeze
        @timestamp_attributes_for_update_in_model = (model_class.timestamp_attributes_for_update & @column_names).freeze
        @all_timestamp_attributes_in_model = (@timestamp_attributes_for_create_in_model + @timestamp_attributes_for_update_in_model).freeze

        model_class.make_pending_attribute_modifications_shareable
        initialize_attributes

        @schema_loaded = true
      end

      private
        def custom_table_name?
          model_class.method(:table_name).owner != ModelSchema::ClassMethods
        end

        def custom_primary_key?
          model_class.method(:primary_key).owner != AttributeMethods::PrimaryKey::ClassMethods
        end

        def default_table_name
          return @default_table_name if defined?(@default_table_name)
          return @table_name_definition if @table_name_definition != ModelSchema::ClassMethods::UNDEFINED_TABLE_NAME

          @default_table_name = inferred_table_name
        end

        def compute_table_name
          if model_class.base_class?
            parent = model_class.module_parent
            if parent < Base && !parent.abstract_class?
              contained = parent.table_name
              contained = contained.singularize if parent.pluralize_table_names
              contained += "_"
            end

            name = model_class.model_name.to_s.demodulize.underscore
            name = name.pluralize if model_class.pluralize_table_names
            "#{model_class.full_table_name_prefix}#{contained}#{name}#{model_class.full_table_name_suffix}".freeze
          else
            model_class.base_class.table_name
          end
        end

        def default_primary_key_definition
          return @default_primary_key_definition if @default_primary_key_definition

          if !model_class.base_class? && !@primary_key_declared
            @default_primary_key_definition = ActiveRecord::Key.for(model_class.base_class.primary_key)
          elsif @primary_key_default
            @default_primary_key_definition = @primary_key_default
          else
            @default_primary_key_definition = ActiveRecord::Key.for(get_primary_key(model_class.base_class.name))
          end
          @default_primary_key_definition
        end

        def load_schema
          model_class.load_schema unless schema_loaded?
        end

        def initialize_attributes
          ActiveSupport::Ractors[@attributes_key] ||= Attributes.new(self, build_attribute_set)
        end

        def build_attribute_set
          attributes_hash = @columns_hash.transform_values do |column|
            ActiveModel::Attribute.from_database(column.name, column.default, model_class.type_for_column(column))
          end
          ActiveModel::AttributeSet.new(attributes_hash)
        end

        def derive_query_constraints_list(primary_key)
          if model_class.base_class? || primary_key != model_class.base_class.primary_key
            primary_key if primary_key.is_a?(Array)
          else
            model_class.base_class.query_constraints_definition || (primary_key if primary_key.is_a?(Array))
          end
        end

        def query_constraints
          model_class.query_constraints_definition
        end
    end
  end
end
