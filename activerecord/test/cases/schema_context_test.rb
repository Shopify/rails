# frozen_string_literal: true

require "cases/helper"

class SchemaContextTest < ActiveRecord::TestCase
  def test_model_uses_a_stable_default_schema_context
    model = Class.new(ActiveRecord::Base) do
      self.table_name = "tasks"
    end

    schema_context = model.schema_context

    assert_equal "default", schema_context.context_key
    assert_same schema_context, model.schema_context
    assert_same schema_context.columns_hash, model.columns_hash
    assert_same schema_context.columns, model.columns
    assert_same schema_context.attribute_types, model.attribute_types
  end

  def test_schema_context_object_is_the_replaceable_selection_point
    selector = Class.new do
      attr_accessor :current_schema_context_key

      def initialize(model)
        @model = model
        @contexts = {}
      end

      def columns_hash
        current_context.columns_hash
      end

      def load_schema!
        current_context.load_schema!
      end

      def schema_loaded?
        current_context.schema_loaded?
      end

      def reload_schema_from_cache
        @contexts.each_value(&:reload_schema_from_cache)
      end

      def method_missing(...)
        current_context.public_send(...)
      end

      def respond_to_missing?(...)
        current_context.respond_to?(...) || super
      end

      def current_context
        @contexts[current_schema_context_key] ||= ActiveRecord::ModelSchema::SchemaContext.new(
          @model,
          current_schema_context_key
        )
      end
    end

    model = Class.new(ActiveRecord::Base) do
      self.table_name = "tasks"

      class << self
        attr_writer :schema_context

        def schema_context
          @schema_context
        end
      end
    end

    model.schema_context = selector.new(model)
    model.schema_context.current_schema_context_key = "mysql"
    model.columns_hash
    mysql_context = model.schema_context.current_context

    model.schema_context.current_schema_context_key = "postgresql"
    postgresql_context = model.schema_context.current_context

    assert_not_same mysql_context, postgresql_context
    assert_equal "mysql", mysql_context.context_key
    assert_equal "postgresql", postgresql_context.context_key
    assert_predicate mysql_context, :schema_loaded?
    assert_not_predicate postgresql_context, :schema_loaded?

    model.columns_hash

    assert_predicate postgresql_context, :schema_loaded?
  end

  def test_reloading_schema_resets_the_default_schema_context
    model = Class.new(ActiveRecord::Base) do
      self.table_name = "tasks"
    end

    schema_context = model.schema_context
    model.columns_hash

    assert_predicate schema_context, :schema_loaded?

    model.send(:reload_schema_from_cache)

    assert_same schema_context, model.schema_context
    assert_not_predicate schema_context, :schema_loaded?
  end
end
