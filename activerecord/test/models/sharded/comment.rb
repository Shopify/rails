# frozen_string_literal: true

module Sharded
  class Comment < ActiveRecord::Base
    self.table_name = :sharded_comments
    query_constraints :blog_id, :id

    belongs_to :blog_post
    belongs_to :blog_post_by_id, class_name: "Sharded::BlogPost", foreign_key: :blog_post_id, primary_key: :id
    # setting `foreign_key` should not be neccessary in the future, it will most likely be derived from the association name by convention
    belongs_to :blog_post_with_decoupled_qc, class_name: "Sharded::BlogPost", foreign_key: :blog_post_id, _query_constraints: [:blog_id, :blog_post_id]
    belongs_to :blog
  end
end
