# frozen_string_literal: true

module ActiveRecord
  # The physical key mappings that establish and query an association.
  class AssociationLink # :nodoc:
    attr_reader :reference, :constraints, :match

    def initialize(reference:, constraints: Key::Mapping.empty)
      @reference = reference
      @constraints = constraints
      @match = constraints + reference
      @hash = [@reference, @constraints].hash
      freeze
    end

    def ==(other)
      other.is_a?(AssociationLink) && reference == other.reference && constraints == other.constraints
    end
    alias_method :eql?, :==

    attr_reader :hash

    def write_reference(reference_record, target_record)
      reference.each do |reference_column, target_column|
        value = target_record.read_attribute(target_column)
        if reference_record.read_attribute(reference_column) != value
          reference_record.write_attribute(reference_column, value)
        end
      end
    end
  end
end
