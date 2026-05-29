# frozen_string_literal: true

require "active_support/core_ext/kernel/ractor_shareability"

module ActiveRecord
  class Relation
    class FromClause # :nodoc:
      attr_reader :value, :name

      def initialize(value, name)
        @value = value
        @name = name
      end

      EMPTY = ractor_make_shareable(new(nil, nil))

      def merge(other)
        self
      end

      def empty?
        value.nil?
      end

      def ==(other)
        self.class == other.class && value == other.value && name == other.name
      end

      def self.empty
        EMPTY
      end
    end
  end
end
