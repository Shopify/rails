# frozen_string_literal: true

module Arel # :nodoc: all
  module Attributes
    extend ActiveSupport::Autoload

    eager_autoload do
      autoload :Attribute
    end
  end
end
