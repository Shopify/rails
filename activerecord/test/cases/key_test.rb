# frozen_string_literal: true

require "cases/helper"
require "models/cpk"
require "models/topic"

class KeyTest < ActiveRecord::TestCase
  Key = ActiveRecord::Key

  def test_for_dispatches_to_polymorphic_subclass
    assert_instance_of Key::Single, Key.for("id")
    assert_instance_of Key::Composite, Key.for([:shop_id, :id])
    assert_instance_of Key::None, Key.for(nil)

    assert_kind_of Key, Key.for("id")
    assert_kind_of Key, Key.for([:shop_id, :id])
  end

  def test_simple_key_shape
    pk = Key.for("id")

    assert_not_predicate pk, :composite?
    assert_predicate pk, :present?
    assert_equal "id", pk.name
    assert_equal ["id"], pk.columns
    assert_equal 1, pk.length
  end

  def test_composite_key_shape
    pk = Key.for([:shop_id, :id])

    assert_predicate pk, :composite?
    assert_predicate pk, :present?
    assert_equal ["shop_id", "id"], pk.name
    assert_equal ["shop_id", "id"], pk.columns
    assert_equal 2, pk.length
  end

  def test_missing_key
    pk = Key.for(nil)

    assert_not_predicate pk, :composite?
    assert_not_predicate pk, :present?
    assert_nil pk.name
    assert_empty pk.columns
  end

  def test_columns_are_frozen_strings
    pk = Key.for([:shop_id, :id])

    assert pk.columns.frozen?
    assert(pk.columns.all?(&:frozen?))
  end

  def test_map_retains_array_results_for_scalar_and_composite_keys
    value = [10, 20]

    assert_equal [value], Key.for(:payload).map { value }
    assert_equal [value], Key.for([:payload]).map { value }
    assert_empty Key.for(nil).map { flunk "Mapped a missing key" }
  end

  def test_map_value_returns_a_scalar_without_wrapping_it
    value = [10, 20]
    columns = []
    result = Key.for(:payload).map_value do |column|
      columns << column
      value
    end

    assert_equal ["payload"], columns
    assert_same value, result
    assert_nil Key.for(:payload).map_value { nil }
    assert_equal false, Key.for(:payload).map_value { false }
  end

  def test_map_value_preserves_composite_shape_and_component_values
    value = [10, 20]
    attributes = { "tenant_id" => 7, "payload" => value }
    result = Key.for([:tenant_id, :payload]).map_value { |column| attributes.fetch(column) }

    assert_equal [7, value], result
    assert_same value, result.last
    assert_equal [nil, false], Key.for([:missing, :disabled]).map_value { |column| column == "disabled" ? false : nil }
  end

  def test_map_value_preserves_singleton_composite_shape
    value = [10, 20]
    result = Key.for([:payload]).map_value { value }

    assert_equal [value], result
    assert_same value, result.first
  end

  def test_map_value_preserves_missing_and_empty_composite_shapes
    assert_nil Key.for(nil).map_value { flunk "Mapped a missing key" }
    assert_equal [], Key.for([]).map_value { flunk "Mapped an empty composite key" }
  end

  def test_map_value_supports_indexed_mapping_without_losing_shape
    value = [10, 20]
    cases = [
      [:payload, [value], value],
      [[:payload], [value], [value]],
      [[:tenant_id, :payload], [7, value], [7, value]],
      [[:payload, :payload], [nil, false], [nil, false]],
      [nil, [], nil],
      [[], [], []],
    ]

    cases.each do |name, values, expected|
      key = Key.for(name)
      columns = []
      result = key.map_value.with_index do |column, index|
        columns << column
        values[index]
      end

      assert_equal key.columns, columns
      if expected.nil?
        assert_nil result
      else
        assert_equal expected, result
      end
      assert_same value, result if name == :payload
    end
  end

  def test_transform_returns_a_frozen_scalar_key
    key = Key.for(:id)
    transformed = key.transform { |column| "parent_#{column}" }

    assert_instance_of Key::Single, transformed
    assert_equal "parent_id", transformed.name
    assert_equal "id", key.name
    assert_predicate transformed, :frozen?
    assert_predicate transformed.name, :frozen?
  end

  def test_transform_preserves_composite_key_shape
    key = Key.for([:tenant_id, :id])
    aliases = { "tenant_id" => :account_id, "id" => :post_id }
    transformed = key.transform { |column| aliases.fetch(column) }

    assert_instance_of Key::Composite, transformed
    assert_equal ["account_id", "post_id"], transformed.name
    assert_equal ["tenant_id", "id"], key.name
    assert_predicate transformed, :frozen?
    assert_predicate transformed.columns, :frozen?
    assert(transformed.columns.all?(&:frozen?))
    assert_equal ["post_id"], Key.for([:id]).transform { :post_id }.name
  end

  def test_transform_preserves_missing_and_empty_composite_keys
    key = Key.for(nil)
    assert_same key, key.transform { flunk "Transformed a missing key" }
    transformed = Key.for([]).transform { flunk "Transformed an empty composite key" }

    assert_instance_of Key::Composite, transformed
    assert_empty transformed.columns
    assert_predicate transformed, :frozen?
  end

  def test_zip_pairs_key_columns
    assert_equal [["post_id", "id"]], Key.for(:post_id).zip(Key.for(:id))
    assert_equal [["post_id", "id"]], Key.for([:post_id]).zip(Key.for(:id))
    assert_equal [["post_id", "id"]], Key.for(:post_id).zip(Key.for([:id]))
    assert_equal [["shop_id", "shop_id"], ["post_id", "id"]],
      Key.for([:shop_id, :post_id]).zip(Key.for([:shop_id, :id]))
  end

  def test_zip_uses_the_receiving_keys_length
    assert_empty Key.for(nil).zip(Key.for(:id))
    assert_empty Key.for([]).zip(Key.for(nil))
    assert_equal [["post_id", nil]], Key.for(:post_id).zip(Key.for(nil))
    assert_equal [["shop_id", "id"], ["post_id", nil]], Key.for([:shop_id, :post_id]).zip(Key.for(:id))
    assert_equal [["post_id", "shop_id"]], Key.for(:post_id).zip(Key.for([:shop_id, :id]))
  end

  def test_zip_yields_columns_to_a_block
    pairs = []
    result = Key.for([:shop_id, :post_id]).zip(Key.for([:shop_id, :id])) do |left, right|
      pairs << [left, right]
    end

    assert_nil result
    assert_equal [["shop_id", "shop_id"], ["post_id", "id"]], pairs
  end

  def test_mapping_preserves_column_pairs
    reference_key = Key.for([:account_id, :post_id])
    target_key = Key.for([:account_id, :id])
    mapping = Key::Mapping.new(reference_key: reference_key, target_key: target_key)

    assert_same reference_key, mapping.reference_key
    assert_same target_key, mapping.target_key

    assert_equal [
      ["account_id", "account_id"],
      ["post_id", "id"],
    ], mapping.to_a
    assert_equal ["account_id", "post_id"], mapping.reference_key.name
    assert_equal ["account_id", "id"], mapping.target_key.name
    assert_not_predicate mapping, :empty?
  end

  def test_mapping_requires_equal_arity
    error = assert_raises(ArgumentError) do
      Key::Mapping.new(
        reference_key: Key.for([:account_id, :post_id]),
        target_key: Key.for(:id)
      )
    end

    assert_equal "Key mappings must have the same number of columns", error.message
  end

  def test_mapping_rejects_a_populated_key_paired_with_an_empty_key
    [[nil, :id], [:id, nil], [[], :id], [:id, []]].each do |reference, target|
      assert_raises(ArgumentError) do
        Key::Mapping.new(reference_key: Key.for(reference), target_key: Key.for(target))
      end
    end
  end

  def test_mapping_composes_corresponding_keys
    constraints = Key::Mapping.new(
      reference_key: Key.for(:account_id),
      target_key: Key.for(:account_id)
    )
    reference = Key::Mapping.new(
      reference_key: Key.for(:post_id),
      target_key: Key.for(:id)
    )

    assert_equal [
      ["account_id", "account_id"],
      ["post_id", "id"],
    ], (constraints + reference).to_a
  end

  def test_mapping_preserves_singleton_composite_keys
    reference_key = Key.for([:post_id])
    target_key = Key.for([:id])
    mapping = Key::Mapping.new(reference_key: reference_key, target_key: target_key)

    assert_same reference_key, mapping.reference_key
    assert_same target_key, mapping.target_key
    assert_predicate mapping.reference_key, :composite?
    assert_predicate mapping.target_key, :composite?
    assert_equal [["post_id", "id"]], mapping.to_a
  end

  def test_empty_mapping_reuses_a_shared_empty_key
    mapping = Key::Mapping.empty

    assert_same mapping, Key::Mapping.empty
    assert_predicate mapping, :empty?
    assert_same mapping.reference_key, mapping.target_key
    assert_not_predicate mapping.reference_key, :present?
    assert_empty mapping.to_a
    assert_predicate mapping, :frozen?
    assert_predicate mapping.reference_key, :frozen?
  end

  if RUBY_VERSION >= "4.0"
    def test_empty_mapping_is_shared_across_ractors
      assert_same Key::Mapping.empty, Ractor.new { Key::Mapping.empty }.value
    end
  end

  def test_empty_mapping_preserves_the_other_mapping_and_its_shape
    [[:post_id, :id], [[:post_id], [:id]], [[:account_id, :post_id], [:account_id, :id]]].each do |reference, target|
      mapping = Key::Mapping.new(reference_key: Key.for(reference), target_key: Key.for(target))

      assert_same mapping, Key::Mapping.empty + mapping
      assert_same mapping, mapping + Key::Mapping.empty
    end
  end

  def test_mapping_normalize_scalarizes_single_column_keys_without_changing_the_original
    [[:post_id, [:id]], [[:post_id], :id], [[:post_id], [:id]]].each do |reference, target|
      reference_key = Key.for(reference)
      target_key = Key.for(target)
      mapping = Key::Mapping.new(reference_key: reference_key, target_key: target_key)
      normalized = mapping.normalize

      assert_equal "post_id", normalized.reference_key.name
      assert_equal "id", normalized.target_key.name
      assert_not_predicate normalized.reference_key, :composite?
      assert_not_predicate normalized.target_key, :composite?
      assert_predicate normalized, :frozen?
      assert_same normalized, normalized.normalize
      assert_same reference_key, mapping.reference_key
      assert_same target_key, mapping.target_key
      assert_same reference_key, normalized.reference_key unless reference_key.composite?
      assert_same target_key, normalized.target_key unless target_key.composite?
    end
  end

  def test_mapping_normalize_reuses_already_normalized_mappings
    [[:post_id, :id], [[:account_id, :post_id], [:account_id, :id]], [nil, nil], [[], []]].each do |reference, target|
      mapping = Key::Mapping.new(reference_key: Key.for(reference), target_key: Key.for(target))

      assert_same mapping, mapping.normalize
    end
  end

  def test_where_hash_for_simple_key
    assert_equal({ "id" => 5 }, Key.for("id").where_hash(5))
    assert_equal({ "id" => [1, 2, 3] }, Key.for("id").where_hash([1, 2, 3]))
  end

  def test_where_hash_for_composite_key
    pk = Key.for([:shop_id, :id])

    assert_equal({ "shop_id" => 1, "id" => 5 }, pk.where_hash([1, 5]))
  end

  def test_expects_multiple_ids_for_simple_key
    pk = Key.for("id")

    assert_not pk.expects_multiple_ids?(5)
    assert pk.expects_multiple_ids?([1, 2, 3])
    assert pk.expects_multiple_ids?([])
  end

  def test_expects_multiple_ids_for_composite_key
    pk = Key.for([:shop_id, :id])

    # A single composite id is itself an Array...
    assert_not pk.expects_multiple_ids?([1, 5])
    # ...so several ids are an Array of Arrays.
    assert pk.expects_multiple_ids?([[1, 5], [1, 6]])
    # ...and an empty Array is an empty set of ids.
    assert pk.expects_multiple_ids?([])
  end

  def test_inferred_id_picks_id_from_tenant_shaped_key
    assert_equal "id", Key.for([:shop_id, :id]).inferred_id
    assert_equal ["shop_id", "owner_id"], Key.for([:shop_id, :owner_id]).inferred_id
    assert_nil Key.for("id").inferred_id
  end

  def test_cast_uses_model_column_types
    pk = Cpk::Book.primary_key_definition

    assert_predicate pk, :composite?
    assert_equal [1, 3], pk.cast(["1", "3"], Cpk::Book)

    assert_equal 5, Topic.primary_key_definition.cast("5", Topic)
  end

  def test_composite_cast_preserves_input_and_pads_or_truncates_to_the_key
    key = Key.for([:author_id, :id])
    values = ["1", "3"].freeze

    assert_equal [1, 3], key.cast(values, Cpk::Book)
    assert_equal ["1", "3"], values
    assert_equal [1, nil], key.cast(["1"], Cpk::Book)
    assert_equal [nil, nil], key.cast([], Cpk::Book)
    assert_equal [1, 3], key.cast(["1", "3", "unused"], Cpk::Book)
  end

  def test_composite_cast_accepts_enumerables_without_reading_past_the_key
    key = Key.for([:author_id, :id])
    values = Enumerator.new do |yielder|
      yielder << "1"
      yielder << "3"
      flunk "Read beyond the key's columns"
    end

    assert_equal [1, 3], key.cast(values, Cpk::Book)
    assert_equal [1, nil], key.cast(["1"].each, Cpk::Book)
    assert_equal [nil, nil], key.cast([].each, Cpk::Book)
  end

  def test_composite_cast_preserves_singleton_and_empty_key_shapes
    assert_equal [5], Key.for([:id]).cast(["5"], Topic)
    assert_equal [5], Key.for([:id]).cast(["5"].each, Topic)
    assert_equal [], Key.for([]).cast(Enumerator.new { flunk "Read values for an empty key" }, Topic)
  end

  def test_composite_cast_uses_each_column_type_and_resolves_aliases
    key = Key.for([:id, :approved, :heading])

    assert_equal [12, false, "123"], key.cast(["12", false, 123], Topic)
    assert_equal [12, false, nil], key.cast(["12", false, nil].each, Topic)
  end

  def test_value_of_reads_attributes_from_record
    book = Cpk::Book.new(id: [1, 3])
    assert_equal [1, 3], Cpk::Book.primary_key_definition.value_of(book)

    topic = Topic.new(id: 7)
    assert_equal 7, Topic.primary_key_definition.value_of(topic)
  end

  def test_value_of_applies_a_scalar_normalizer
    topic = Topic.new(id: 7)
    key = Key.for(:id)

    assert_equal "7", key.value_of(topic, [:to_s.to_proc])
    assert_equal 7, key.value_of(topic, nil)
    assert_equal 7, key.value_of(topic, [nil])
    assert_equal 7, topic.id
  end

  def test_value_of_applies_normalizers_by_column_position
    book = Cpk::Book.new(id: [1, 3])
    key = Cpk::Book.primary_key_definition

    assert_equal [1, "3"], key.value_of(book, [nil, :to_s.to_proc])
    assert_equal [11, 3], key.value_of(book, [->(value) { value + 10 }, nil])
    assert_equal [1, 3], key.value_of(book, nil)
    assert_equal [1, 3], book.id

    repeated_key = Key.for([:id, :id])
    assert_equal ["7", 7], repeated_key.value_of(Topic.new(id: 7), [:to_s.to_proc, nil])
  end

  def test_value_of_preserves_falsy_normalizer_results
    topic = Topic.new(id: 7)
    assert_nil Key.for(:id).value_of(topic, [->(_) { nil }])
    assert_equal false, Key.for(:id).value_of(topic, [->(_) { false }])

    book = Cpk::Book.new(id: [1, 3])
    assert_equal [nil, false], Cpk::Book.primary_key_definition.value_of(book, [->(_) { nil }, ->(_) { false }])
  end

  def test_value_of_normalizes_array_valued_components_without_changing_key_shape
    topic = Topic.new
    value = [10, 20]
    normalizer = ->(component) { component + [30] }

    topic.stub(:read_attribute, value) do
      assert_same value, Key.for(:payload).value_of(topic, [nil])
      assert_equal [10, 20, 30], Key.for(:payload).value_of(topic, [normalizer])
      assert_equal [[10, 20, 30]], Key.for([:payload]).value_of(topic, [normalizer])
      assert_equal [], Key.for([]).value_of(topic, [])
    end
    assert_equal [10, 20], value
  end

  def test_model_exposes_definition
    assert_not_predicate Topic.primary_key_definition, :composite?
    assert_equal "id", Topic.primary_key_definition.name

    assert_predicate Cpk::Book.primary_key_definition, :composite?
    assert_equal ["author_id", "id"], Cpk::Book.primary_key_definition.name
  end
end
