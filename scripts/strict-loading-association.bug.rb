# frozen_string_literal: true

require "active_record/railtie"
require "minitest/autorun"

# This connection will do for database-independent bug reports.
ENV["DATABASE_URL"] = "sqlite3::memory:"

class TestApp < Rails::Application
  config.load_defaults Rails::VERSION::STRING.to_f
  config.eager_load = false
  config.logger = Logger.new($stdout)
  config.secret_key_base = "secret_key_base"

  config.active_record.encryption.primary_key = "primary_key"
  config.active_record.encryption.deterministic_key = "deterministic_key"
  config.active_record.encryption.key_derivation_salt = "key_derivation_salt"
end
Rails.application.initialize!

ActiveRecord::Schema.define do
  create_table :posts, force: true do |t|
  end

  create_table :comments, force: true do |t|
    t.integer :post_id
    t.string :content
  end
end

class Post < ActiveRecord::Base
  has_many :comments
end

class Comment < ActiveRecord::Base
  belongs_to :post
end

class BugTest < ActiveSupport::TestCase
  def test_association_stuff
    post = Post.create!
    comment = post.comments.create!(content: "Hello")

    require "debug"; debugger

    comment_reload = Comment.includes(post: :comments).find(comment.id)

    comment_reload.update!(content: "Hello 2")

    # require "debug"; debugger

    post = comment_reload.post
    # require "debug"; debugger
    comments = post.comments
    assert_equal "Hello 2", comments.first.content
  end
end
