# frozen_string_literal: true

require_relative "../abstract_unit"

module OtherAfterTeardown
  def after_teardown
    super

    @witness = true
  end
end

class AfterTeardownTest < ActiveSupport::TestCase
  include OtherAfterTeardown

  attr_writer :witness

  MyError = Class.new(StandardError)

  teardown do
    raise MyError, "Test raises an error, all after_teardown should still get called"
  end

  def after_teardown
    # FIXME: Megatest doesn't offer this as public API. Not sure we want to, maybe just remove the test
    assert_changes -> { @__m.instance_variable_get(:@result).failures.count }, from: 0, to: 1 do
      super
    end

    assert_equal true, @witness
    failures.clear
  end

  def test_teardown_raise_but_all_after_teardown_method_are_called
    assert true
  end
end
