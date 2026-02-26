# frozen_string_literal: true

class Step < ActiveRecord::Base
  belongs_to :recipe, touch: true, context: {
    default: { primary_key: :id },
    other: { primary_key: [:id, :chef_id] }
  }
  belongs_to :chef
end
