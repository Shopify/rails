# frozen_string_literal: true

module ActiveRecord
  module Type
    class Model < ActiveModel::Type::Model
      def initialize(**options)
        options.with_defaults!(serializer: ActiveSupport::JSON)

        super
      end
    end
  end
end
