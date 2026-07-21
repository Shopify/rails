# frozen_string_literal: true

require "cases/helper"

module ActiveRecord
  class CaseInsensitiveTableNamesTest < ActiveRecord::AbstractMysqlTestCase
    def setup
      @connection = ActiveRecord::Base.lease_connection
      @connection.drop_table(:MixedCaseTbl, if_exists: true)
    end

    def teardown
      @connection.drop_table(:MixedCaseTbl, if_exists: true)
    end

    # With lower_case_table_names = 1 or 2, table-name comparison is
    # case-insensitive, so introspecting "mixedcasetbl" must find the table
    # stored as "MixedCaseTbl". The single-table APIs and SchemaCache#add must
    # attribute the result to the requested name without depending on the
    # database's own (differently-cased) table name.
    def test_introspection_with_wrong_case_table_name
      skip "only relevant when table name comparison is case-insensitive" if lower_case_table_names.to_i == 0

      @connection.create_table(:MixedCaseTbl, force: true) do |t|
        t.string :name
        t.integer :custom_id
      end
      @connection.add_index(:MixedCaseTbl, :name)

      assert_equal %w[id name custom_id], @connection.columns("mixedcasetbl").map(&:name)
      assert_equal %w[id], @connection.primary_keys("mixedcasetbl")
      assert_equal 1, @connection.indexes("mixedcasetbl").size

      cache = ActiveRecord::Base.connection_pool.schema_cache
      cache.clear_data_source_cache!("mixedcasetbl")
      cache.add("mixedcasetbl")

      assert_equal %w[id name custom_id], cache.columns("mixedcasetbl").map(&:name)
      assert_equal "id", cache.primary_keys("mixedcasetbl")
      assert_equal 1, cache.indexes("mixedcasetbl").size
    end

    private
      def lower_case_table_names
        @connection.show_variable("lower_case_table_names")
      end
  end
end
