# frozen_string_literal: true

module ActiveRecord
  class PredicateBuilder
    class PolymorphicArrayValue # :nodoc:
      def initialize(reflection, values, origin_model)
        @reflection = reflection
        @values = values
        @origin_model = origin_model
      end

      def queries
        return [ reflection.join_foreign_key => values ] if values.empty?

        queries = route_groups.filter_map do |_key, (fixed_values, origin_key, ids)|
          fixed_values.merge(origin_key => ids) unless ids.empty?
        end
        queries.empty? ? [{}] : queries
      end

      private
        attr_reader :reflection, :values

        def route_groups
          values.each_with_object({}) do |value, groups|
            if route = route_for(value)
              fixed_values = route.fixed_reference_values
              origin_key = route.origin_key.name
              key = [fixed_values, origin_key]
            else
              fixed_values = {}
              origin_key = reflection.join_foreign_key
              key = [fixed_values, origin_key]
            end

            group = groups[key] ||= [fixed_values, origin_key, []]
            ids = convert_to_id(value, route)
            if value.is_a?(Relation) && route.destination_key.composite?
              group.last.concat(ids)
            else
              group.last << ids
            end
          end
        end

        def route_for(value)
          if value.is_a?(Base) || value.is_a?(Relation)
            destination_class = value.is_a?(Relation) ? value.model : value.class
            reflection.association_route(origin_class: @origin_model, destination_class: destination_class)
          end
        end

        def convert_to_id(value, route)
          if value.is_a?(Base)
            route.destination_key.value_of(value)
          elsif value.is_a?(Relation)
            if route.destination_key.composite?
              value.pluck(route.destination_key.name)
            else
              value.select(route.destination_key.name)
            end
          else
            value
          end
        end
    end
  end
end
