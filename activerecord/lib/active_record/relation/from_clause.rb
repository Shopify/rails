# frozen_string_literal: true

require "active_support/core_ext/object/shareable"

module ActiveRecord
  class Relation
    class FromClause # :nodoc:
      attr_reader :value, :name

      def initialize(value, name)
        @value = value
        @name = name
      end

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
        @empty ||= new(nil, nil).make_shareable!
      end
    end
  end
end
