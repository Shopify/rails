# frozen_string_literal: true

require "cases/helper"
require "active_support/core_ext/object/with"
require "models/book"
require "models/liquid"
require "models/molecule"
require "models/numeric_data"
require "models/electron"
require "models/clothing_item"

module ActiveRecord
  class StatementCacheTest < ActiveRecord::TestCase
    def setup
      @connection = ActiveRecord::Base.lease_connection
    end

    def test_statement_cache
      Book.create(name: "my book")
      Book.create(name: "my other book")

      cache = StatementCache.create(ClothingItem.lease_connection) do |params|
        Book.where(name: params.bind)
      end

      b = cache.execute([ "my book" ], ClothingItem.lease_connection)
      assert_equal "my book", b[0].name
      b = cache.execute([ "my other book" ], ClothingItem.lease_connection)
      assert_equal "my other book", b[0].name
    end

    def test_statement_cache_id
      b1 = Book.create(name: "my book")
      b2 = Book.create(name: "my other book")

      cache = StatementCache.create(ClothingItem.lease_connection) do |params|
        Book.where(id: params.bind)
      end

      b = cache.execute([ b1.id ], ClothingItem.lease_connection)
      assert_equal b1.name, b[0].name
      b = cache.execute([ b2.id ], ClothingItem.lease_connection)
      assert_equal b2.name, b[0].name
    end

    def test_find_or_create_by
      Book.create(name: "my book")

      a = Book.find_or_create_by(name: "my book")
      b = Book.find_or_create_by(name: "my other book")

      assert_equal("my book", a.name)
      assert_equal("my other book", b.name)
    end

    def test_statement_cache_with_simple_statement
      cache = ActiveRecord::StatementCache.create(ClothingItem.lease_connection) do |params|
        Book.where(name: "my book").where("author_id > 3")
      end

      Book.create(name: "my book", author_id: 4)

      books = cache.execute([], ClothingItem.lease_connection)
      assert_equal "my book", books[0].name
    end

    def test_statement_cache_with_complex_statement
      cache = ActiveRecord::StatementCache.create(ClothingItem.lease_connection) do |params|
        Liquid.joins(molecules: :electrons).where("molecules.name" => "dioxane", "electrons.name" => "lepton")
      end

      salty = Liquid.create(name: "salty")
      molecule = salty.molecules.create(name: "dioxane")
      molecule.electrons.create(name: "lepton")

      liquids = cache.execute([], ClothingItem.lease_connection)
      assert_equal "salty", liquids[0].name
    end

    def test_statement_cache_with_strictly_cast_attribute
      row = NumericData.create(temperature: 1.5)
      assert_equal row, NumericData.find_by(temperature: 1.5)
    end

    def test_statement_cache_values_differ
      cache = ActiveRecord::StatementCache.create(ClothingItem.lease_connection) do |params|
        Book.where(name: "my book")
      end

      3.times do
        Book.create(name: "my book")
      end

      first_books = cache.execute([], ClothingItem.lease_connection)

      3.times do
        Book.create(name: "my book")
      end

      additional_books = cache.execute([], ClothingItem.lease_connection)
      assert_not_equal first_books, additional_books
    end

    def test_shared_statement_cache_keeps_fixed_and_variable_binds_executable
      first = Book.create!(name: "first shared book", author_id: 4)
      second = Book.create!(name: "second shared book", author_id: 4)
      Book.create!(name: "first shared book", author_id: 5)

      cache = StatementCache.create(@connection) do |params|
        Book.where(name: params.bind, author_id: 4)
      end
      ActiveSupport::Ractors.make_shareable(cache)

      assert_equal [first.id], cache.execute(["first shared book"], @connection).map(&:id)
      assert_equal [second.id], cache.execute(["second shared book"], @connection).map(&:id)
    end

    def test_threaded_find_by_cache_preserves_mutable_custom_types
      ActiveSupport::Ractors.with(unshareable_proc_action: nil) do
        type = Class.new(ActiveRecord::Type::String) do
          def serialize(value)
            @last_serialized_value = super
          end
        end.new
        model = Class.new(Book)
        model.attribute :name, type
        book = model.create!(name: "mutable type")

        assert_equal book, model.find_by(name: "mutable type")
        assert_nil model.find_by(name: "missing")
      end
    end

    def test_unprepared_statements_dont_share_a_cache_with_prepared_statements
      Book.create(name: "my book")
      Book.create(name: "my other book")

      book = Book.find_by(name: "my book")
      other_book = Book.lease_connection.unprepared_statement do
        Book.find_by(name: "my other book")
      end

      assert_not_equal book, other_book
    end

    def test_out_of_range_bind_value_returns_an_empty_result
      cache = Book.lease_connection.unprepared_statement do
        StatementCache.create(Book.lease_connection) do |params|
          Book.where(id: params.bind)
        end
      end

      assert_equal [], cache.execute([2 << 63], Book.lease_connection)
    end

    def test_out_of_range_bind_value_returns_an_empty_result_when_async
      cache = Book.lease_connection.unprepared_statement do
        StatementCache.create(Book.lease_connection) do |params|
          Book.where(id: params.bind)
        end
      end

      promise = cache.execute([2 << 63], Book.lease_connection, async: true)

      assert promise.is_a?(ActiveRecord::Promise)
      assert_equal [], promise.value
    end

    def test_find_by_does_not_use_statement_cache_if_table_name_is_changed
      liquid = Liquid.create(name: "salty")

      Liquid.find_by(name: liquid.name) # warming the statement cache.

      # changing the table name should change the query that is not cached.
      Liquid.table_name = :birds
      assert_nil Liquid.find_by(name: liquid.name)
    ensure
      Liquid.table_name = :liquid
    end

    def test_find_does_not_use_statement_cache_if_table_name_is_changed
      liquid = Liquid.create(name: "salty")

      Liquid.find(liquid.id) # warming the statement cache.

      # changing the table name should change the query that is not cached.
      Liquid.table_name = :birds
      assert_raise ActiveRecord::RecordNotFound do
        Liquid.find(liquid.id)
      end
    ensure
      Liquid.table_name = :liquid
    end

    def test_find_association_does_not_use_statement_cache_if_table_name_is_changed
      salty = Liquid.create(name: "salty")
      molecule = salty.molecules.create(name: "dioxane")

      assert_equal salty, molecule.liquid

      Liquid.table_name = :birds

      assert_nil molecule.reload_liquid
    ensure
      Liquid.table_name = :liquid
    end
  end
end
