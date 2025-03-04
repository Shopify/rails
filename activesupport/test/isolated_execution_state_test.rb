# frozen_string_literal: true

require_relative "abstract_unit"

class IsolatedExecutionStateTest < ActiveSupport::TestCase
  setup do
    ActiveSupport::IsolatedExecutionState.clear
    @original_isolation_level = ActiveSupport::IsolatedExecutionState.isolation_level
  end

  teardown do
    ActiveSupport::IsolatedExecutionState.clear
    ActiveSupport::IsolatedExecutionState.isolation_level = @original_isolation_level
  end

  test "#[] when isolation level is :fiber" do
    ActiveSupport::IsolatedExecutionState.isolation_level = :fiber

    ActiveSupport::IsolatedExecutionState[:test] = 42
    assert_equal 42, ActiveSupport::IsolatedExecutionState[:test]
    enumerator = Enumerator.new do |yielder|
      yielder.yield ActiveSupport::IsolatedExecutionState[:test]
    end
    assert_nil enumerator.next

    assert_nil Thread.new { ActiveSupport::IsolatedExecutionState[:test] }.value
  end

  test "#[] when isolation level is :thread" do
    ActiveSupport::IsolatedExecutionState.isolation_level = :thread

    ActiveSupport::IsolatedExecutionState[:test] = 42
    assert_equal 42, ActiveSupport::IsolatedExecutionState[:test]
    enumerator = Enumerator.new do |yielder|
      yielder.yield ActiveSupport::IsolatedExecutionState[:test]
    end
    assert_equal 42, enumerator.next

    assert_nil Thread.new { ActiveSupport::IsolatedExecutionState[:test] }.value
  end

  test "#[] when isolation level is :fiber_storage, state separated between threads" do
    ActiveSupport::IsolatedExecutionState.isolation_level = :fiber_storage

    Thread.new do
      ActiveSupport::IsolatedExecutionState[:test] = 42
      assert_equal 42, ActiveSupport::IsolatedExecutionState[:test]
    end

    assert_nil ActiveSupport::IsolatedExecutionState[:test]
  end

  test "#[] when isolation level is :fiber_storage, child fibers / threads inherit state" do
    ActiveSupport::IsolatedExecutionState.isolation_level = :fiber_storage

    ActiveSupport::IsolatedExecutionState[:test] = 42
    assert_equal 42, ActiveSupport::IsolatedExecutionState[:test]
    enumerator = Enumerator.new do |yielder|
      yielder.yield ActiveSupport::IsolatedExecutionState[:test]
    end

    assert_equal 42, enumerator.next
    assert_equal 42, Thread.new { ActiveSupport::IsolatedExecutionState[:test] }.value
  end

  test "#[] when isolation level is :fiber_storage, child fibers / threads do not mutate parent" do
    ActiveSupport::IsolatedExecutionState.isolation_level = :fiber_storage

    ActiveSupport::IsolatedExecutionState[:test] = 42
    assert_equal 42, ActiveSupport::IsolatedExecutionState[:test]
    enumerator = Enumerator.new do |yielder|
      ActiveSupport::IsolatedExecutionState[:test] = 99
      yielder.yield ActiveSupport::IsolatedExecutionState[:test]
    end

    assert_equal 99, enumerator.next
    assert_equal 42, ActiveSupport::IsolatedExecutionState[:test]
  end

  test "changing the isolation level clear the old store" do
    original = ActiveSupport::IsolatedExecutionState.isolation_level
    other = ActiveSupport::IsolatedExecutionState.isolation_level == :fiber ? :thread : :fiber

    ActiveSupport::IsolatedExecutionState[:test] = 42
    ActiveSupport::IsolatedExecutionState.isolation_level = original
    assert_equal 42, ActiveSupport::IsolatedExecutionState[:test]

    ActiveSupport::IsolatedExecutionState.isolation_level = other
    assert_nil ActiveSupport::IsolatedExecutionState[:test]

    ActiveSupport::IsolatedExecutionState.isolation_level = original
    assert_nil ActiveSupport::IsolatedExecutionState[:test]
  end
end
