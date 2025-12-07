# frozen_string_literal: true

require "cases/helper"

class CollectionAttributeTest < ActiveRecord::TestCase
  self.use_transactional_tests = false

  class CollectionDataTypeOnText < ActiveRecord::Base
    attribute :integers, :collection, element_type: :integer
  end

  class CollectionDataTypeOnJson < ActiveRecord::Base
    attribute :integers, :collection, element_type: :integer
  end

  setup do
    @connection = ActiveRecord::Base.lease_connection
    @connection.create_table(CollectionDataTypeOnText.table_name, force: true) { |t| t.text :integers }
    @connection.create_table(CollectionDataTypeOnJson.table_name, force: true) { |t| t.json :integers }
  end

  teardown do
    @connection.drop_table CollectionDataTypeOnText.table_name, if_exists: true
    @connection.drop_table CollectionDataTypeOnJson.table_name, if_exists: true
    CollectionDataTypeOnText.reset_column_information
    CollectionDataTypeOnJson.reset_column_information
  end

  test "writes :collection attribute instance to text column" do
    integers = ["1", "2", "3"]
    record = CollectionDataTypeOnText.create!(integers: integers)

    assert_equal integers.map(&:to_i), record.integers
  end

  test "writes :collection attribute instance to json column" do
    integers = ["1", "2", "3"]
    record = CollectionDataTypeOnJson.create!(integers: integers)

    assert_equal integers.map(&:to_i), record.integers
  end

  test "reads nil :collection attribute instance from text column" do
    record = CollectionDataTypeOnText.create!(integers: nil)

    assert_empty record.integers
  end

  test "reads nil :collection attribute instance from json column" do
    record = CollectionDataTypeOnJson.create!(integers: nil)

    assert_empty record.integers
  end
end
