# frozen_string_literal: true

module AsyncHelper
  private
    def assert_async_api(relation, code)
      caller = caller_locations(1, 1).first
      sync_result = relation.instance_eval(code, caller.path, caller.lineno)
      async_result = relation.async.instance_eval(code, caller.path, caller.lineno)

      message = "Expected async.#{code} to return an ActiveRecord::Promise, got: #{async_result.inspect}"
      assert ActiveRecord::Promise === async_result, message

      assert_equal sync_result, async_result.value
    end
end
