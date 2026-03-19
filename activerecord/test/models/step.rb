# frozen_string_literal: true

class Step < ActiveRecord::Base
  belongs_to :recipe
  belongs_to :chef
end
