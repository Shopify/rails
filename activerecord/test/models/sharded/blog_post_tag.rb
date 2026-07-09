# frozen_string_literal: true

module Sharded
  class BlogPostTag < ActiveRecord::Base
    self.table_name = :sharded_blog_posts_tags
    query_constraints :blog_id, :id

    belongs_to :blog_post
    belongs_to :tag
    belongs_to :tag_with_decoupled_qc, class_name: "Sharded::Tag", foreign_key: :tag_id, query_constraints: :blog_id
    # foreign_type is set explicitly because the association name
    # (taggable_with_decoupled_qc) diverges from the taggable_* column prefix, so
    # the default derived type column (taggable_with_decoupled_qc_type) would not
    # exist. The decoupled query_constraints feature itself does not require it;
    # the motivating :region shape (region_id/region_type) needs no override.
    belongs_to :taggable_with_decoupled_qc,
      polymorphic: true,
      foreign_key: :taggable_id,
      foreign_type: :taggable_type,
      query_constraints: :blog_id
  end
end
