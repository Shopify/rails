# frozen_string_literal: true

require "cases/helper"

module SchemaLoadCounter
  extend ActiveSupport::Concern

  module ClassMethods
    attr_accessor :load_schema_calls

    def load_schema!
      self.load_schema_calls ||= 0
      self.load_schema_calls += 1
      super
    end
  end
end

class SchemaLoadingTest < ActiveRecord::TestCase
  def test_schema_context_owns_primary_key_without_loading_columns
    klass = define_model { |model| model.table_name = "topics" }
    klass.schema_cache.stub(:columns_hash, ->(*) { flunk "Primary key resolution loaded columns" }) do
      assert_equal "id", klass.primary_key
      assert_equal "id", klass.schema_context.primary_key
      assert_not_predicate klass.schema_context, :schema_loaded?
    end
  end

  def test_content_columns_uses_inheritance_column_set_after_primary_key_resolution
    klass = define_model { |model| model.table_name = "topics" }
    assert_equal "id", klass.primary_key

    klass.inheritance_column = "author_name"

    assert_not_includes klass.content_columns.map(&:name), "author_name"
  end

  def test_inheritance_column_change_refreshes_loaded_descendant_content_columns
    klass = define_model { |model| model.table_name = "topics" }
    models = [klass, Class.new(klass)]
    models.each do |model|
      assert_includes model.content_columns.map(&:name), "author_name"
    end

    klass.inheritance_column = "author_name"

    models.each do |model|
      assert_not_includes model.content_columns.map(&:name), "author_name"
    end
  end

  def test_loaded_schema_context_retains_its_column_metadata_after_model_configuration_changes
    klass = define_model { |model| model.table_name = "topics" }
    context = klass.schema_context
    assert_includes context.column_names, "title"

    klass.table_name = "subscribers"

    assert_includes context.column_names, "title"
    assert_not_includes klass.column_names, "title"
  end

  def test_declared_primary_key_can_be_read_before_first_table_name_assignment
    klass = Class.new(ActiveRecord::Base) { self.primary_key = "id" }
    assert_equal "id", klass.primary_key

    klass.table_name = "topics"

    assert_equal "id", klass.primary_key
    assert_includes klass.column_names, "title"
  end

  def test_failed_schema_initialization_does_not_publish_column_metadata
    klass = define_model
    context = klass.schema_context

    klass.stub(:make_pending_attribute_modifications_shareable, -> { raise "schema initialization failed" }) do
      assert_raises(RuntimeError) { klass.column_names }
    end

    assert_nil klass.current_schema_context
    assert_not_same context, klass.schema_context
    assert_includes klass.column_names, "id"
    assert_equal 1, klass.load_schema_calls
  end

  def test_failed_schema_hook_does_not_publish_the_context
    klass = define_model

    klass.stub(:load_schema!, -> { raise "schema hook failed" }) do
      assert_raises(RuntimeError) { klass.column_names }
    end

    assert_nil klass.current_schema_context
    assert_includes klass.column_names, "id"
    assert_equal 1, klass.load_schema_calls
  end

  def test_basic_model_is_loaded_once
    klass = define_model
    klass.new
    assert_equal 1, klass.load_schema_calls
  end

  def test_model_with_custom_lock_is_loaded_once
    klass = define_model do |c|
      c.table_name = :lock_without_defaults_cust
      c.locking_column = :custom_lock_version
    end
    klass.new
    assert_equal 1, klass.load_schema_calls
  end

  def test_model_with_changed_custom_lock_is_loaded_twice
    klass = define_model do |c|
      c.table_name = :lock_without_defaults_cust
    end
    klass.new
    klass.locking_column = :custom_lock_version
    klass.new
    assert_equal 2, klass.load_schema_calls
  end

  def test_schema_loading_doesnt_query_when_schema_cache_is_loaded
    with_temporary_connection_pool do
      if in_memory_db?
        # Separate connections to an in-memory database create an entirely new database,
        # with an empty schema etc, so we just stub out this schema on the fly.
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.create_table :tasks do |t|
            t.datetime :starting
            t.datetime :ending
          end
        end
      end

      klass = define_model do |c|
        c.table_name = :tasks
      end

      klass.connection_pool.schema_cache.load!
      klass.connection_pool.schema_cache.add("tasks")
      klass.connection_pool.disconnect!
      klass.send(:reload_schema_from_cache)


      assert_no_queries(include_schema: true) do
        klass.load_schema
      end
      assert_equal 1, klass.load_schema_calls
    end
  end

  private
    def define_model
      Class.new(ActiveRecord::Base) do
        include SchemaLoadCounter
        self.table_name = :lock_without_defaults
        yield self if block_given?
      end
    end
end
