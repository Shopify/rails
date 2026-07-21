# frozen_string_literal: true

require "cases/helper"
require "models/post"
require "models/comment"

module ActiveRecord
  module ConnectionAdapters
    class SchemaTest < ActiveRecord::AbstractMysqlTestCase
      fixtures :posts

      def setup
        @connection = ActiveRecord::Base.lease_connection
        db          = Post.connection_pool.db_config.database
        table       = Post.table_name
        @db_name    = db

        @omgpost = Class.new(ActiveRecord::Base) do
          self.inheritance_column = :disabled
          self.table_name = "#{db}.#{table}"
          def self.name; "Post"; end
        end
      end

      def test_float_limits
        @connection.create_table :mysql_doubles do |t|
          t.float :float_no_limit
          t.float :float_short, limit: 5
          t.float :float_long, limit: 53

          t.float :float_23, limit: 23
          t.float :float_24, limit: 24
          t.float :float_25, limit: 25
        end

        column_no_limit = @connection.columns(:mysql_doubles).find { |c| c.name == "float_no_limit" }
        column_short = @connection.columns(:mysql_doubles).find { |c| c.name == "float_short" }
        column_long = @connection.columns(:mysql_doubles).find { |c| c.name == "float_long" }

        column_23 = @connection.columns(:mysql_doubles).find { |c| c.name == "float_23" }
        column_24 = @connection.columns(:mysql_doubles).find { |c| c.name == "float_24" }
        column_25 = @connection.columns(:mysql_doubles).find { |c| c.name == "float_25" }

        # MySQL floats are precision 0..24, MySQL doubles are precision 25..53
        assert_equal 24, column_no_limit.limit
        assert_equal 24, column_short.limit
        assert_equal 53, column_long.limit

        assert_equal 24, column_23.limit
        assert_equal 24, column_24.limit
        assert_equal 53, column_25.limit
      ensure
        @connection.drop_table "mysql_doubles", if_exists: true
      end

      def test_schema
        assert @omgpost.first
      end

      def test_primary_key
        assert_equal "id", @omgpost.primary_key
      end

      def test_data_source_exists?
        name = @omgpost.table_name
        assert @connection.data_source_exists?(name), "#{name} data_source should exist"
      end

      def test_data_source_exists_wrong_schema
        assert_not(@connection.data_source_exists?("#{@db_name}.zomg"), "data_source should not exist")
      end

      def test_dump_indexes
        index_a_name = "index_key_tests_on_snack"
        index_b_name = "index_key_tests_on_pizza"
        index_c_name = "index_key_tests_on_awesome"

        table = "key_tests"

        indexes = @connection.indexes(table).sort_by(&:name)
        assert_equal 3, indexes.size

        index_a = indexes.select { |i| i.name == index_a_name }[0]
        index_b = indexes.select { |i| i.name == index_b_name }[0]
        index_c = indexes.select { |i| i.name == index_c_name }[0]
        assert_equal :btree, index_a.using
        assert_nil index_a.type
        assert_equal :btree, index_b.using
        assert_nil index_b.type

        assert_nil index_c.using
        assert_equal :fulltext, index_c.type
      end

      def test_indexes_for_multiple_tables
        @connection.create_table(:idx_multi_a) { |t| t.string :email; t.string :name }
        @connection.create_table(:idx_multi_b) { |t| t.string :email; t.string :other }
        # "by_email" is idx_multi_a's alphabetically-last index and
        # idx_multi_b's alphabetically-first, so the rows are adjacent across
        # the two tables in the ORDER BY. A name-only index boundary would fail
        # to start a new index for idx_multi_b's "by_email" and crash.
        @connection.add_index :idx_multi_a, :name,  name: "aaa_name"
        @connection.add_index :idx_multi_a, :email, name: "by_email"
        @connection.add_index :idx_multi_b, :email, name: "by_email"
        @connection.add_index :idx_multi_b, :other, name: "zzz_other"

        # A single table name returns an Array of indexes (backward compatible).
        single = @connection.indexes("idx_multi_a")
        assert_kind_of Array, single
        assert_equal %w[aaa_name by_email], single.map(&:name).sort

        # indexes_for_tables returns a Hash of table name => Array of indexes.
        multi = @connection.indexes_for_tables(["idx_multi_a", "idx_multi_b"])
        assert_kind_of Hash, multi
        assert_equal %w[idx_multi_a idx_multi_b], multi.keys.sort
        assert multi.values.all?(Array)
        assert_equal %w[aaa_name by_email], multi["idx_multi_a"].map(&:name).sort
        assert_equal %w[by_email zzz_other], multi["idx_multi_b"].map(&:name).sort

        # A non-primary index name shared across two tables must not merge:
        # each table's "by_email" keeps its own columns and table attribute.
        a = multi["idx_multi_a"].find { |i| i.name == "by_email" }
        b = multi["idx_multi_b"].find { |i| i.name == "by_email" }
        assert_equal %w[email], a.columns
        assert_equal %w[email], b.columns
        assert_equal "idx_multi_a", a.table
        assert_equal "idx_multi_b", b.table
      ensure
        @connection.drop_table :idx_multi_a, if_exists: true
        @connection.drop_table :idx_multi_b, if_exists: true
      end

      def test_indexes_for_multiple_tables_with_qualified_and_unqualified_names
        @connection.create_table(:idx_mix_a) { |t| t.string :name }
        @connection.create_table("#{@db_name}.idx_mix_b") { |t| t.string :other }
        @connection.add_index :idx_mix_a, :name, name: "mix_a_name"
        @connection.add_index "#{@db_name}.idx_mix_b", :other, name: "mix_b_other"

        # Mixing a schema-qualified name with an unqualified one yields a
        # multi-clause (OR) scope. The trailing AND index_name != 'PRIMARY'
        # must filter every clause; without parenthesizing the scope it binds
        # only to the last clause and the primary key leaks in as a "PRIMARY"
        # index for the other table.
        multi = @connection.indexes_for_tables(["#{@db_name}.idx_mix_b", :idx_mix_a])
        assert_equal %w[mix_b_other], multi["idx_mix_b"].map(&:name).sort
        assert_equal %w[mix_a_name], multi["idx_mix_a"].map(&:name).sort
      ensure
        @connection.drop_table :idx_mix_a, if_exists: true
        @connection.drop_table "#{@db_name}.idx_mix_b", if_exists: true
      end

      unless mysql_enforcing_gtid_consistency?
        def test_drop_temporary_table
          @connection.transaction do
            @connection.create_table(:temp_table, temporary: true)
            assert_nothing_raised do
              # if it doesn't properly say DROP TEMPORARY TABLE, the transaction commit
              # will complain that no transaction is active
              @connection.drop_table(:temp_table, temporary: true)
            end
          end
        end
      end
    end
  end
end

class MysqlAnsiQuotesTest < ActiveRecord::AbstractMysqlTestCase
  def setup
    @connection = ActiveRecord::Base.lease_connection
    @connection.execute("SET SESSION sql_mode='ANSI_QUOTES'")
  end

  def teardown
    @connection.reconnect!
  end

  def test_primary_key_method_with_ansi_quotes
    assert_equal "id", @connection.primary_key("topics")
  end

  def test_foreign_keys_method_with_ansi_quotes
    fks = @connection.foreign_keys("lessons_students")
    assert_equal([["lessons_students", "students", :cascade]],
                 fks.map { |fk| [fk.from_table, fk.to_table, fk.on_delete] })
  end
end
