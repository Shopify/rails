# frozen_string_literal: true

begin
    require "bundler/inline"
  rescue LoadError => e
    $stderr.puts "Bundler version 1.10 or later is required. Please update your Bundler"
    raise e
  end
  
  gemfile(true) do
    source "https://rubygems.org"
  
    git_source(:github) { |repo| "https://github.com/#{repo}.git" }
  
    gem "rails", path: "/home/spin/src/github.com/Shopify/rails/"
    gem "sqlite3"
    gem 'pry', '~> 0.13.1'
  end
  
  require "active_record"
  require "minitest/autorun"
  require "logger"
  
  # This connection will do for database-independent bug reports.
  ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
  ActiveRecord::Base.logger = Logger.new(STDOUT)
  
  ActiveRecord::Schema.define do
    create_table :posts, force: true do |t|
      t.integer :owner_id
      t.string :title
    end
  
    create_table :comments, force: true do |t|
      t.integer :post_id
    end
  
    create_table :owners, force: true do |t|
      t.integer :post_id
      t.string :name
    end
  end
  
  class Post < ActiveRecord::Base
    belongs_to :owner
    has_many :comments
  end
  
  class Comment < ActiveRecord::Base
    belongs_to :post
    has_one :owner, through: :post
  end
  
  class Owner < ActiveRecord::Base
  end
  
  class BugTest < Minitest::Test
    def test_association_stuff
      owner = Owner.new(name: "cool_post_owner")
      post = Post.new(owner: owner, title: "A cool post")
      comment = Comment.new
      post.comments << comment
  

      binding.pry
      refute_nil comment.post.title
      assert_equal post.title, comment.post.title
      # passes when not using the has_one through association
      assert_equal owner.name, post.comments.first.post.owner.name
      # fails when using the has_one through association
      assert_equal owner.name, post.comments.first.owner.name
    end
  end