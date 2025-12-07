# frozen_string_literal: true

require "cases/helper"

class ModelAttributeTest < ActiveRecord::TestCase
  self.use_transactional_tests = false

  class Author
    include ActiveModel::Model
    include ActiveModel::Dirty
    include ActiveModel::Attributes

    attribute :name, :string
  end

  class Post
    include ActiveModel::Model
    include ActiveModel::Dirty
    include ActiveModel::Attributes

    attribute :author, :model, class_name: Author.name
    attribute :title, :string
    attribute :published_on, :datetime

    alias_attribute :name, :title
  end

  class ModelDataTypeOnText < ActiveRecord::Base
    attribute :post, :model, class_name: Post.name
  end

  class ModelDataTypeOnJson < ActiveRecord::Base
    attribute :post, :model, class_name: Post.name
  end

  setup do
    @connection = ActiveRecord::Base.lease_connection
    @connection.create_table(ModelDataTypeOnText.table_name, force: true) { |t| t.text :post }
    @connection.create_table(ModelDataTypeOnJson.table_name, force: true) { |t| t.json :post }
  end

  teardown do
    @connection.drop_table ModelDataTypeOnText.table_name, if_exists: true
    @connection.drop_table ModelDataTypeOnJson.table_name, if_exists: true
    ModelDataTypeOnText.reset_column_information
    ModelDataTypeOnJson.reset_column_information
  end

  test "writes :model attribute instance to text column" do
    post = Post.new(title: "Rails", published_on: "2025-12-06")
    record = ModelDataTypeOnText.create!(post: post)

    assert_equal post.attributes.to_json, record.post_before_type_cast
  end

  test "writes :model attribute Hash to text column" do
    post = Post.new(title: "Rails", published_on: "2025-12-06")
    record = ModelDataTypeOnText.create!(post: post.attributes)

    assert_kind_of Post, record.post
    assert_equal post.attributes.to_json, record.post_before_type_cast
  end

  test "writes nested :model instance attribute to text column" do
    attributes = { author: { name: "Matz" }, title: nil, published_on: nil }
    author = Author.new(attributes[:author])
    post = Post.new(author: author)
    record = ModelDataTypeOnText.create!(post: post)

    assert_kind_of Author, record.post.author
    assert_equal attributes.to_json, record.post_before_type_cast
  end

  test "writes nested :model Hash attribute to text column" do
    attributes = { author: { name: "Matz" }, title: nil, published_on: nil }
    record = ModelDataTypeOnText.create!(post: attributes)

    assert_kind_of Author, record.post.author
    assert_equal(attributes.to_json, record.post_before_type_cast)
  end

  test "writes aliased attribute to text column" do
    post = Post.new(name: "Rails", published_on: "2025-12-06")
    record = ModelDataTypeOnText.create!(post: post)

    value = JSON.parse(record.post_before_type_cast)

    assert_equal "Rails", value["title"]
  end

  test "reads :model attribute from text column" do
    post = Post.new(title: "Rails")
    record = ModelDataTypeOnText.create!(post: post)

    record.reload

    assert_kind_of Post, record.post
    assert_equal post.attributes, record.post.attributes
  end

  test "reads nested :model attribute from text column" do
    author = Author.new(name: "Matz")
    post = Post.new(author: author)
    record = ModelDataTypeOnText.create!(post: post)

    record.reload

    assert_kind_of Author, record.post.author
    assert_equal author.attributes, record.post.author.attributes
  end

  test "reads aliased attribute from text column" do
    post = Post.new(name: "Rails")
    record = ModelDataTypeOnText.create!(post: post)

    record.reload

    assert_equal "Rails", record.post.name
    assert_equal "Rails", record.post.title
  end

  test "writes :model attribute instance to json column" do
    post = Post.new(title: "Rails", published_on: "2025-12-06")
    record = ModelDataTypeOnJson.create!(post: post)

    assert_equal post.attributes.to_json, record.post_before_type_cast
  end

  test "writes :model attribute Hash to json column" do
    post = Post.new(title: "Rails", published_on: "2025-12-06")
    record = ModelDataTypeOnJson.create!(post: post.attributes)

    assert_kind_of Post, record.post
    assert_equal post.attributes.to_json, record.post_before_type_cast
  end

  test "writes nested :model instance attribute to json column" do
    attributes = { author: { name: "Matz" }, title: nil, published_on: nil }
    author = Author.new(attributes[:author])
    post = Post.new(author: author)
    record = ModelDataTypeOnJson.create!(post: post)

    assert_kind_of Author, record.post.author
    assert_equal attributes.to_json, record.post_before_type_cast
  end

  test "writes nested :model Hash attribute to json column" do
    attributes = { author: { name: "Matz" }, title: nil, published_on: nil }
    record = ModelDataTypeOnJson.create!(post: attributes)

    assert_kind_of Author, record.post.author
    assert_equal(attributes.to_json, record.post_before_type_cast)
  end

  test "writes aliased attribute to json column" do
    post = Post.new(name: "Rails", published_on: "2025-12-06")
    record = ModelDataTypeOnJson.create!(post: post)

    value = JSON.parse(record.post_before_type_cast)

    assert_equal "Rails", value["title"]
  end

  test "reads :model attribute from json column" do
    post = Post.new(title: "Rails")
    record = ModelDataTypeOnJson.create!(post: post)

    record.reload

    assert_kind_of Post, record.post
    assert_equal post.attributes, record.post.attributes
  end

  test "reads nested :model attribute from json column" do
    author = Author.new(name: "Matz")
    post = Post.new(author: author)
    record = ModelDataTypeOnJson.create!(post: post)

    record.reload

    assert_kind_of Author, record.post.author
    assert_equal author.attributes, record.post.author.attributes
  end

  test "reads aliased attribute from json column" do
    post = Post.new(name: "Rails")
    record = ModelDataTypeOnJson.create!(post: post)

    record.reload

    assert_equal "Rails", record.post.name
    assert_equal "Rails", record.post.title
  end

  test "delegates to :model attribute dirty checking when available" do
    record = ModelDataTypeOnText.create!(post: Post.new(title: "Ruby"))

    assert_changes -> { record.changed? }, from: false, to: true do
      record.post.title = "Rails"
    end
    assert_equal "Rails", record.post.title
    assert_predicate record.post, :title_changed?
  end

  test "delegates to nested :model attribute dirty checking when available" do
    author = Author.new(name: "Matz")
    post = Post.new(author: author)
    record = ModelDataTypeOnText.create!(post: post)

    assert_changes -> { record.changed? }, from: false, to: true do
      record.post.author.name = "Changed"
    end
    assert_equal "Changed", record.post.author.name
    assert_predicate record.post.author, :name_changed?
  end
end
