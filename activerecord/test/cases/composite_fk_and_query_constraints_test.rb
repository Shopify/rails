# frozen_string_literal: true

require "cases/helper"
require "models/sharded/comment"
require "models/sharded/blog_post"

# Verifies that a composite (array) foreign_key and a query_constraints column
# that is NOT part of the foreign_key can be declared together on one
# association. The defining behavior is decoupled nullification: clearing the
# association nulls the foreign_key columns but leaves the query_constraint column.
class CompositeFkAndQueryConstraintsTest < ActiveRecord::TestCase
  fixtures :sharded_comments, :sharded_blog_posts

  def test_load_uses_fk_columns_and_the_query_constraint_column
    comment = sharded_comments(:great_comment_blog_post_one)
    expected_blog_post = sharded_blog_posts(:great_post_blog_one)

    sql = capture_sql do
      assert_equal expected_blog_post, comment.blog_post_composite_fk_with_qc
    end.first

    quoted = ->(col) { Regexp.escape(Sharded::BlogPost.lease_connection.quote_table_name("sharded_blog_posts.#{col}")) }
    # FK columns (composite) participate...
    assert_match(/#{quoted.call("blog_id")} =/, sql)
    assert_match(/#{quoted.call("id")} =/, sql)
    # ...and so does the additive query_constraint column that is NOT in the FK.
    assert_match(/#{quoted.call("region_id")} =/, sql)
  end

  def test_clearing_nulls_only_foreign_key_columns_not_the_query_constraint_column
    comment = sharded_comments(:great_comment_blog_post_one)
    assert_equal 1, comment.region_id

    # Assert in-memory, before any save: clearing writes only the FK columns.
    # (Saving is avoided because blog_id is also a component of Comment's own
    # composite primary key, so persisting a nulled PK is a synthetic artifact
    # unrelated to which columns the association clear touches.)
    comment.blog_post_composite_fk_with_qc = nil
    assert_nil comment.blog_id
    assert_nil comment.blog_post_id
    assert_equal 1, comment.region_id
  end
end
