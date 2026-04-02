# frozen_string_literal: true

module Sharded
  class BlogPost < ActiveRecord::Base
    self.table_name = :sharded_blog_posts
    query_constraints :blog_id, :id

    belongs_to :parent, polymorphic: true
    belongs_to :blog
    has_many :comments
    has_many :delete_comments, class_name: "Sharded::Comment", dependent: :delete_all
    has_many :children, class_name: name, as: :parent

    has_many :blog_post_tags
    has_many :tags, through: :blog_post_tags

    has_many :comments_with_composite_pk,
      class_name: "Sharded::Comment",
      primary_key: [:blog_id, :id],
      query_constraints: [:blog_id, :blog_post_id]

    belongs_to :featured_comment,
      class_name: "Sharded::Comment",
      foreign_key: :featured_comment_id,
      query_constraints: [:blog_id, { id: :blog_post_id }]
  end
end
