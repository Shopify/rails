# frozen_string_literal: true

require "cases/helper"

class SchemaContextTest < ActiveRecord::TestCase
  def test_model_uses_a_lazy_default_schema_context
    model = Class.new(ActiveRecord::Base) do
      self.table_name = "tasks"
    end

    assert_not model.instance_variable_defined?(:@schema_context)

    schema_context = model.schema_context

    assert_instance_of ActiveRecord::ModelSchema::SchemaContext, schema_context
    assert_equal "default", schema_context.context_key
    assert_same schema_context, model.schema_context
    assert_same schema_context.columns_hash, model.columns_hash
    assert_same schema_context.columns, model.columns
    assert_same schema_context.attribute_types, model.attribute_types
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
