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

  test "#set when underlying isolation level is :fiber_storage provides inheritable context" do
    previous_isolation_level = ActiveSupport::IsolatedExecutionState.isolation_level
    ActiveSupport::IsolatedExecutionState.isolation_level = :fiber_storage

    ActiveSupport::ExecutionContext.set(foo: "bar") do
      assert_equal "bar", ActiveSupport::ExecutionContext.to_h[:foo]

      Fiber.new do
        assert_equal "bar", ActiveSupport::ExecutionContext.to_h[:foo]

        ActiveSupport::ExecutionContext.set(foo: "baz")
        assert_equal "baz", ActiveSupport::ExecutionContext.to_h[:foo]
      end.resume

      assert_equal "bar", ActiveSupport::ExecutionContext.to_h[:foo]
    end
  ensure
    ActiveSupport::IsolatedExecutionState.isolation_level = previous_isolation_level
  end

  test "#[]= coerce keys to symbol" do
    ActiveSupport::ExecutionContext["symbol_key"] = "symbolized"
    assert_equal "symbolized", ActiveSupport::ExecutionContext.to_h[:symbol_key]
  end

  test "#[]= underlying isolation level is :fiber_storage provides inheritable context" do
    previous_isolation_level = ActiveSupport::IsolatedExecutionState.isolation_level
    ActiveSupport::IsolatedExecutionState.isolation_level = :fiber_storage

    ActiveSupport::ExecutionContext[:foo] = "bar"
    assert_equal "bar", ActiveSupport::ExecutionContext.to_h[:foo]

    Fiber.new do
      assert_equal "bar", ActiveSupport::ExecutionContext.to_h[:foo]

      ActiveSupport::ExecutionContext[:foo] = "baz"
      assert_equal "baz", ActiveSupport::ExecutionContext.to_h[:foo]
    end.resume

    assert_equal "bar", ActiveSupport::ExecutionContext.to_h[:foo]
  ensure
    ActiveSupport::IsolatedExecutionState.isolation_level = previous_isolation_level

  end

  test "#to_h returns a copy of the context" do
    ActiveSupport::ExecutionContext[:foo] = 42
    context = ActiveSupport::ExecutionContext.to_h
    context[:foo] = 43
    assert_equal 42, ActiveSupport::ExecutionContext.to_h[:foo]
  end
end
