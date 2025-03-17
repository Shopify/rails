# frozen_string_literal: true

require_relative "abstract_unit"
require "active_support/execution_context/test_helper"

class ExecutionContextTest < ActiveSupport::TestCase
  # ExecutionContext is automatically reset in Rails app via executor hooks set in railtie
  # But not in Active Support's own test suite.
  include ActiveSupport::ExecutionContext::TestHelper

  test "#set restore the modified keys when the block exits" do
    assert_nil ActiveSupport::ExecutionContext.to_h[:foo]
    ActiveSupport::ExecutionContext.set(foo: "bar") do
      assert_equal "bar", ActiveSupport::ExecutionContext.to_h[:foo]
      ActiveSupport::ExecutionContext.set(foo: "plop") do
        assert_equal "plop", ActiveSupport::ExecutionContext.to_h[:foo]
      end
      assert_equal "bar", ActiveSupport::ExecutionContext.to_h[:foo]

      ActiveSupport::ExecutionContext[:direct_assignment] = "present"
      ActiveSupport::ExecutionContext.set(multi_assignment: "present")
    end

    assert_nil ActiveSupport::ExecutionContext.to_h[:foo]

    assert_equal "present", ActiveSupport::ExecutionContext.to_h[:direct_assignment]
    assert_equal "present", ActiveSupport::ExecutionContext.to_h[:multi_assignment]
  end

  test "#set coerce keys to symbol" do
    ActiveSupport::ExecutionContext.set("foo" => "bar") do
      assert_equal "bar", ActiveSupport::ExecutionContext.to_h[:foo]
    end
  end

  test "#[]= coerce keys to symbol" do
    ActiveSupport::ExecutionContext["symbol_key"] = "symbolized"
    assert_equal "symbolized", ActiveSupport::ExecutionContext.to_h[:symbol_key]
  end

  test "#to_h returns a copy of the context" do
    ActiveSupport::ExecutionContext[:foo] = 42
    context = ActiveSupport::ExecutionContext.to_h
    context[:foo] = 43
    assert_equal 42, ActiveSupport::ExecutionContext.to_h[:foo]
  end

  test "#set with :fiber_storage based IsolatedExecutionState" do
    execution_context = ActiveSupport::ExecutionContext.new(ActiveSupport::FiberStorageIsolatedExecutionState.new)

    execution_context.set(foo: "bar") do
      assert_equal "bar", execution_context.to_h[:foo]

      Fiber.new do
        assert_equal "bar", execution_context.to_h[:foo]

        execution_context.set(foo: "baz")
        assert_equal "baz", execution_context.to_h[:foo]
      end.resume

      assert_equal "bar", execution_context.to_h[:foo]
    end
  end

  test "#[]= with :fiber_storage based IsolatedExecutionState" do
    execution_context = ActiveSupport::ExecutionContext.new(ActiveSupport::FiberStorageIsolatedExecutionState.new)

    execution_context[:foo] = "bar"
    assert_equal "bar", execution_context.to_h[:foo]

    Fiber.new do
      assert_equal "bar", execution_context.to_h[:foo]

      execution_context.set(foo: "baz")
      assert_equal "baz", execution_context.to_h[:foo]
    end.resume

    assert_equal "bar", execution_context.to_h[:foo]
  end

  test "#clear with :fiber_storage based IsolatedExecutionState" do
    execution_context = ActiveSupport::ExecutionContext.new(ActiveSupport::FiberStorageIsolatedExecutionState.new)

    execution_context[:foo] = "bar"

    Fiber.new do
      execution_context.clear
      assert_empty execution_context.to_h
    end.resume

    assert_equal "bar", execution_context.to_h[:foo]
  end
end
