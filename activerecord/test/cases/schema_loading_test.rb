# frozen_string_literal: true

require "cases/helper"
require "concurrent/atomic/count_down_latch"

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
    original_context = klass.schema_context

    assert_equal "id", klass.primary_key
    assert_not_predicate original_context, :schema_loaded?

    klass.table_name = "subscribers"
    selected_context = klass.schema_context

    assert_nil klass.primary_key
    assert_not_predicate selected_context, :schema_loaded?
    assert_equal "id", original_context.primary_key

    klass.primary_key = "nick"
    assert_equal "nick", klass.primary_key
    assert_nil selected_context.primary_key

    klass.define_singleton_method(:schema_context) { original_context }
    assert_equal "id", klass.primary_key
    assert_not_predicate original_context, :schema_loaded?
  end

  def test_schema_context_loads_schema_when_columns_are_requested
    klass = define_model
    context = nil

    assert_no_queries(include_schema: true) do
      context = klass.schema_context
      assert_same context, klass.schema_context
      assert_not_predicate context, :schema_loaded?
    end

    assert_includes context.column_names, "id"
    assert_same context, klass.schema_context
    assert_predicate context, :schema_loaded?
    assert_equal 1, klass.load_schema_calls
  end

  def test_independent_primary_key_resolution_can_run_concurrently_with_schema_loading
    klass = define_model { |model| model.table_name = "topics" }
    cache = klass.schema_cache
    cache.add("topics")
    metadata_started = Concurrent::CountDownLatch.new(1)
    resume_key_read = Concurrent::CountDownLatch.new(1)
    primary_keys = lambda do |table_name|
      if Thread.current.name == "primary_key_reader"
        metadata_started.count_down
        resume_key_read.wait
      end
      "id"
    end

    cache.stub(:primary_keys, primary_keys) do
      reader = Thread.new do
        Thread.current.name = "primary_key_reader"
        klass.primary_key
      end
      reader.report_on_exception = false
      assert metadata_started.wait(5), "The primary key read did not reach metadata resolution"

      # A column read triggers the full schema load.
      loader = Thread.new { klass.column_names }
      loader.report_on_exception = false
      # Allow the schema load to finish first, or to wait for independent primary key resolution.
      loader.join(1)
      resume_key_read.count_down

      assert_equal "id", reader.value
      assert_includes loader.value, "id"
    ensure
      resume_key_read.count_down
      reader&.kill
      loader&.kill
    end
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
