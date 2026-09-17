# frozen_string_literal: true

module ActiveRecord
  class PredicateBuilder
    class AssociationQueryValue # :nodoc:
      def initialize(reflection, value, origin_class)
        @reflection = reflection
        @value = value
        @origin_class = origin_class
      end

      def queries
        if value.nil?
          [nil_query]
        elsif value.is_a?(Array) && value.any?(&:nil?)
          non_nil_values = value.compact
          if non_nil_values.empty?
            [nil_query]
          else
            [nil_query, *queries_for_array(non_nil_values)]
          end
        elsif value.is_a?(Array)
          queries_for_array(value)
        else
          route = association_route_for(value)
          queries_for_ids(value, route, record_or_relation?(value))
        end
      end

      private
        attr_reader :reflection, :value

        def queries_for_array(values)
          if values.none? { |record| record_or_relation?(record) }
            queries_for_ids(values, association_route_for(nil), false)
          else
            values.group_by do |record|
              route = association_route_for(record)
              [route, record_or_relation?(record)]
            end.flat_map do |(route, query_match), records|
              queries_for_ids(records, route, query_match)
            end
          end
        end

        def queries_for_ids(query_value, route, query_match)
          key = query_match ? route.origin_key : route.reference_origin_key
          id_list = ids(query_value, route, query_match)
          id_list = id_list.pluck(primary_key(route, query_match)) if key.composite? && id_list.is_a?(Relation)
          return [{}] if id_list.is_a?(Array) && id_list.empty?

          key.where_clauses(id_list)
        end

        def nil_query
          key = association_route_for(nil).reference_origin_key
          key.where_hash(key.map_value { nil })
        end

        def ids(query_value, route, query_match)
          primary_key = primary_key(route, query_match)
          case query_value
          when Relation
            relation = query_value
            relation = relation.select(primary_key) if relation.select_values.empty?
            if type = reflection.type
              physical_type = relation.model.attribute_aliases[type] || type
              unless relation.where_values_hash.has_key?(physical_type)
                # Keep the declaring reflection's discriminator for relation predicates.
                relation = relation.where(type => reflection.polymorphic_name)
              end
            end
            relation
          when Array
            query_value.map { |item| convert_to_id(item, primary_key) }
          else
            [convert_to_id(query_value, primary_key)]
          end
        end

        def primary_key(route, query_match)
          if query_match
            route.destination_key.name
          else
            route.reference_destination_key.name
          end
        end

        def association_route_for(target)
          destination_class = case target
          when Relation
            target.model
          when Base
            target.class
          else
            reflection.klass
          end
          reflection.association_route(origin_class: @origin_class, destination_class: destination_class)
        end

        def record_or_relation?(target)
          target.is_a?(Base) || target.is_a?(Relation)
        end

        def convert_to_id(value, primary_key)
          if primary_key.is_a?(Array)
            primary_key.map do |attribute|
              if attribute == "id"
                value.id_value
              else
                value.public_send(attribute)
              end
            end
          elsif value.respond_to?(primary_key)
            value.public_send(primary_key)
          else
            value
          end
        end
    end
  end
end
