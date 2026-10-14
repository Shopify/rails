# frozen_string_literal: true

require_relative "abstract_unit"
require "active_support/weak_key_map"
require "active_support/testing/ractors_assertions"
require "weakref"

class WeakKeyMapTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::RactorsAssertions

  setup do
    @map = ActiveSupport::WeakKeyMap.new
    @key = Object.new
  end

  test "reads and replaces values" do
    assert_nil @map[@key]
    assert_not @map.key?(@key)

    @map[@key] = "first"
    assert @map.key?(@key)
    assert_equal "first", @map[@key]

    @map[@key] = "second"
    assert_equal "second", @map[@key]
  end

  test "equal keys share an entry" do
    key_class = Struct.new(:name)
    original = key_class.new("same")
    equivalent = key_class.new("same")
    value = Object.new
    @map[original] = value

    assert_same value, @map[equivalent]
    assert_same value, @map.fetch_or_store(equivalent) { flunk "The entry exists" }
    assert_same value, @map.delete(equivalent)
    assert_not @map.key?(original)
  end

  test "nil is storable but is not memoized" do
    assert_nil @map.fetch_or_store(@key) { nil }
    assert @map.key?(@key)
    assert_nil @map[@key]
    assert_equal "filled", @map.fetch_or_store(@key) { "filled" }
  end

  test "false is memoized" do
    assert_same false, @map.fetch_or_store(@key) { false }
    assert @map.key?(@key)
    assert_same false, @map.fetch_or_store(@key) { flunk "The entry exists" }
  end

  test "initialization errors leave the entry absent" do
    assert_raises(ArgumentError) do
      @map.fetch_or_store(@key) { raise ArgumentError, "Failed initialization" }
    end

    assert_not @map.key?(@key)
    assert_equal "retried", @map.fetch_or_store(@key) { "retried" }
  end

  test "concurrent misses may compute multiple values" do
    entered, release = Queue.new, Queue.new
    computed = Queue.new
    threads = Array.new(8) do
      Thread.new do
        @map.fetch_or_store(@key) do
          value = Object.new
          computed << value
          entered << true
          release.pop
          value
        end
      end
    end
    8.times { entered.pop }
    8.times { release << true }
    results = threads.map(&:value)
    candidates = Array.new(8) { computed.pop }

    results.each { |result| assert_includes candidates, result }
    assert_includes candidates, @map[@key]
  end

  test "a value published during initialization is not replaced" do
    key_class = Struct.new(:name)
    original, lookup = key_class.new("same"), key_class.new("same")
    published = Object.new

    result = @map.fetch_or_store(lookup) do
      @map[original] = published
      Object.new
    end

    assert_same published, result
    assert_same published, @map[lookup]
  end

  if RUBY_ENGINE == "ruby"
    test "MRI storage has no wrapper or mutex" do
      assert_kind_of ObjectSpace::WeakKeyMap, @map
      assert_empty @map.instance_variables
    end
  end

  test "delete removes the entry" do
    @map[@key] = "value"

    assert_equal "value", @map.delete(@key)
    assert_nil @map.delete(@key)
    assert_not @map.key?(@key)
  end

  test "clear removes entries and returns the map" do
    other_key = Object.new
    @map[@key] = "first"
    @map[other_key] = "second"

    assert_same @map, @map.clear
    assert_not @map.key?(@key)
    assert_not @map.key?(other_key)
    assert_equal "rebuilt", @map.fetch_or_store(@key) { "rebuilt" }
  end

  test "values stay alive while their stored key is alive" do
    reference = Thread.new do
      value = Object.new
      @map[@key] = value
      WeakRef.new(value)
    end.value

    collect_garbage

    assert reference.weakref_alive?
    assert_same reference.__getobj__, @map[@key]
  end

  test "discarded keys release their values" do
    references = Thread.new do
      key, value = Object.new, Object.new
      @map[key] = value
      [WeakRef.new(key), WeakRef.new(value)]
    end.value

    collect_garbage

    references.each { |reference| assert_not reference.weakref_alive? }
  end

  if RUBY_VERSION >= "4.0"
    test "maps can be constructed and used within another Ractor" do
      results = on_ractor do
        map = ActiveSupport::WeakKeyMap.new
        key = Object.new
        first = map.fetch_or_store(key) { Object.new }
        second = map.fetch_or_store(key) { Object.new }
        [first.equal?(second), map.key?(key), map.delete(key).equal?(first), map.key?(key)]
      end

      assert_equal [true, true, true, false], results
    end
  end

  private
    def collect_garbage
      4.times { GC.start(full_mark: true, immediate_sweep: true) }
    end
end
