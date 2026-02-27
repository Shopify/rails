# frozen_string_literal: true

class Step < ActiveRecord::Base
  belongs_to :recipe, touch: true, primary_key: :id, context: {
    other: { primary_key: [:id, :chef_id] }
  }
  belongs_to :chef
end
