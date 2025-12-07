# frozen_string_literal: true

class Post
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :title, :string
  attribute :body, :string

  alias_attribute :name, :title
end
