# frozen_string_literal: true

require "cases/helper"
require "models/post"

module ActiveRecord
  class QueryIntentTest < ActiveRecord::TestCase
    test "finalized intents cannot be delivered or reset" do
      connection = Post.lease_connection
      intent = ActiveRecord::ConnectionAdapters::QueryIntent.new(
        adapter: connection,
        raw_sql: "SELECT 1",
        name: "SQL",
        materialize_transactions: false
      )

      intent.execute!
      intent.cast_result

      assert_predicate intent, :finalized?
      assert_raises(ActiveRecord::ConnectionAdapters::QueryIntent::FinalizedError) do
        intent.deliver_result(nil)
      end
      assert_raises(ActiveRecord::ConnectionAdapters::QueryIntent::FinalizedError) do
        intent.deliver_failure(ActiveRecord::StatementInvalid.new("boom"))
      end
      assert_raises(ActiveRecord::ConnectionAdapters::QueryIntent::FinalizedError) do
        intent.reset_for_retry
      end
    end
  end
end
