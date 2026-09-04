# frozen_string_literal: true

module ActiveRecord
  class PredicateBuilder
    class PolymorphicArrayValue # :nodoc:
      def initialize(reflection, values)
        @reflection = reflection
        @values = values
      end

      def queries
        return [ reflection.foreign_key => values ] if values.empty?

        type_to_ids_mapping.map do |type, ids|
          query = {}
          query[reflection.join_foreign_type] = type if type
          associated_class = reflection.active_record.polymorphic_class_for(type) if type
          key = if associated_class
            reflection.association_join_mapping(associated_class).target_key.name
          else
            reflection.foreign_key
          end
          query[key] = ids
          query
        end
      end

      private
        attr_reader :reflection, :values

        def type_to_ids_mapping
          default_hash = Hash.new { |hsh, key| hsh[key] = [] }
          values.each_with_object(default_hash) do |value, hash|
            hash[klass(value)&.polymorphic_name] << convert_to_id(value)
          end
        end

        def primary_key(value)
          reflection.association_join_mapping(klass(value)).reference_key.name
        end

        def klass(value)
          if value.is_a?(Base)
            value.class
          elsif value.is_a?(Relation)
            value.model
          end
        end

        def convert_to_id(value)
          if value.is_a?(Base)
            ActiveRecord::Key.for(primary_key(value)).value_of(value)
          elsif value.is_a?(Relation)
            value.select(primary_key(value))
          else
            value
          end
        end
    end
  end
end
