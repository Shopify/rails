# frozen_string_literal: true

module ActiveRecord
  module Associations
    # = Active Record Belongs To Association
    class BelongsToAssociation < SingularAssociation # :nodoc:
      attr_reader :foreign_key, :foreign_type

      def initialize(owner, reflection)
        super
        aliases = owner.class.attribute_aliases
        fk = reflection.foreign_key
        resolved_fk = fk.is_a?(Array) ? fk.map { |k| aliases[k] || k } : (aliases[fk] || fk)
        @foreign_key = ActiveRecord::Key.for(resolved_fk)
        if reflection.polymorphic?
          ft = reflection.foreign_type
          @foreign_type = aliases[ft] || ft
        end
      end

      def association_route(record = nil)
        reflection.association_route(origin_class: owner.class, destination_class: record ? record.class : klass)
      end

      def handle_dependency
        return unless load_target

        case options[:dependent]
        when :destroy
          raise ActiveRecord::Rollback unless target.destroy
        when :destroy_async
          route = association_route(target)
          destination_key = route.destination_key
          id = destroy_association_async_id(route, destination_key)
          # Tuple syntax distinguishes an Array-valued key from the job's ID list.
          if !destination_key.composite? && id.is_a?(Array)
            destination_key = ActiveRecord::Key.for(destination_key.columns)
            id = [id]
          end
          association_class = if reflection.polymorphic?
            owner.public_send(foreign_type)
          else
            klass
          end

          enqueue_destroy_association(
            owner_model_name: owner.class.to_s,
            owner_id: owner.id,
            association_class: association_class.to_s,
            association_ids: [id],
            association_primary_key_column: destination_key.name,
            ensuring_owner_was_method: options.fetch(:ensuring_owner_was, nil)
          )
        else
          target.public_send(options[:dependent])
        end
      end

      def inversed_from(record)
        replace_keys(record)
        super
      end

      def default(&block)
        writer(owner.instance_exec(&block)) if reader.nil?
      end

      def reset
        super
        @updated = false
      end

      def updated?
        @updated
      end

      def decrement_counters
        update_counters(-1)
      end

      def increment_counters
        update_counters(1)
      end

      def decrement_counters_before_last_save
        if reflection.polymorphic?
          model_type_was = owner.attribute_before_last_save(foreign_type)
          model_was = owner.class.polymorphic_class_for(model_type_was) if model_type_was
        else
          model_was = klass
        end
        foreign_key_was = foreign_key.map_value { |key| owner.attribute_before_last_save(key) }
        foreign_key_was = nil if foreign_key.composite? && !foreign_key_was.all?

        if foreign_key_was && model_was < ActiveRecord::Base
          route = reflection.association_route(origin_class: owner.class, destination_class: model_was)
          aliases = owner.class.attribute_aliases
          origin_key_was = route.origin_key.map_value { |key| owner.attribute_before_last_save(aliases[key] || key) }
          update_counters_via_scope(model_was, origin_key_was, -1, route)
        end
      end

      def target_changed?
        foreign_key.any? { |fk| owner.attribute_changed?(fk) } || (!foreign_key_present? && target&.new_record?)
      end

      def target_previously_changed?
        foreign_key.any? { |fk| owner.attribute_previously_changed?(fk) }
      end

      def saved_change_to_target?
        foreign_key.any? { |fk| owner.saved_change_to_attribute?(fk) }
      end

      private
        # Prefer the target's persisted values, falling back to the owner for
        # values unavailable after a partial select.
        def destroy_association_async_id(route, destination_key)
          aliases = target.class.attribute_aliases
          origin_columns = route.origin_key.columns
          destination_key.map_value.with_index do |destination_column, index|
            origin_value = owner.read_attribute(origin_columns[index])
            if target.has_attribute?(destination_column)
              destination_value = target.attribute_in_database(aliases[destination_column] || destination_column)
              # An unselected primary key can still be present as nil.
              if !destination_value.nil? || !route.reference_destination_key.include?(destination_column)
                destination_value
              else
                origin_value
              end
            else
              origin_value
            end
          end
        end

        def replace(record)
          if record
            raise_on_type_mismatch!(record)
            set_inverse_instance(record)
            @updated = true
          elsif target
            remove_inverse_instance(target)
          end

          replace_keys(record, force: true)

          self.target = record
        end

        def update_counters(by)
          if require_counter_update? && foreign_key_present?
            if target && !stale_target?
              target.increment!(reflection.counter_cache_column, by, touch: reflection.options[:touch])
            else
              route = association_route
              update_counters_via_scope(klass, route.origin_key.value_of(owner), by, route)
            end
          end
        end

        def update_counters_via_scope(klass, values, by, route)
          scope = klass.all_queries_scope.where!(route.destination_key.where_hash(values))
          scope.update_counters(reflection.counter_cache_column => by, touch: reflection.options[:touch])
        end

        def find_target?
          !loaded? && foreign_key_present? && klass
        end

        def require_counter_update?
          reflection.counter_cache_column && owner.persisted?
        end

        def replace_keys(record, force: false)
          if record.nil? && foreign_key_partially_overlaps_primary_key?
            clear_reference_with_shared_primary_key(force: force)
          else
            route = reflection.association_route(origin_class: owner.class, destination_class: record&.class)
            route.write(owner, record, force: force)
          end
        end

        def foreign_key_partially_overlaps_primary_key?
          primary_key = owner.class.primary_key_definition
          shared_count = foreign_key.count { |key| primary_key.include?(key) }
          shared_count > 0 && shared_count < foreign_key.size
        end

        def clear_reference_with_shared_primary_key(force:)
          primary_key = owner.class.primary_key_definition

          foreign_key.each do |key|
            next if primary_key.include?(key)
            owner.write_attribute(key, nil)
          end

          if foreign_type && (force || !owner.read_attribute(foreign_type).nil?)
            owner.write_attribute(foreign_type, nil)
          end
        end

        def foreign_key_present?
          foreign_key.all? { |fk| owner.read_attribute(fk) }
        end

        def invertible_for?(record)
          inverse = inverse_reflection_for(record)
          inverse && (inverse.has_one? || inverse.klass.has_many_inversing)
        end

        def stale_state
          value = foreign_key.map_value do |fk|
            owner.read_attribute(fk) { |n| owner.send(:missing_attribute, n, caller) }
          end
          foreign_key.composite? ? (value if value.any?) : value
        end
    end
  end
end
