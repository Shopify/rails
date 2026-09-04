# frozen_string_literal: true

module ActiveRecord
  module Associations
    # = Active Record Belongs To Association
    class BelongsToAssociation < SingularAssociation # :nodoc:
      attr_reader :foreign_type

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

      def foreign_key
        return @foreign_key if reflection.polymorphic? && owner.read_attribute(foreign_type).blank?

        key = reflection.association_link(klass).reference.reference_key.name
        aliases = owner.class.attribute_aliases
        key = key.map { |column| aliases[column] || column } if key.is_a?(Array)
        key = aliases[key] || key unless key.is_a?(Array)
        ActiveRecord::Key.for(key)
      rescue NameError
        @foreign_key
      end

      def handle_dependency
        return unless load_target

        case options[:dependent]
        when :destroy
          raise ActiveRecord::Rollback unless target.destroy
        when :destroy_async
          association_class = klass
          match = reflection.association_link(association_class).match
          ids = match.reference_key.map { |column| owner.public_send(column) }

          enqueue_destroy_association(
            owner_model_name: owner.class.to_s,
            owner_id: owner.id,
            association_class: association_class.to_s,
            association_ids: match.reference_key.composite? ? [ids] : ids,
            association_primary_key_column: match.target_key.name,
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

        return unless model_was

        match = reflection.association_link(model_was).match
        values = match.reference_key.map { |key| owner.attribute_before_last_save(key) }
        foreign_key_was = match.reference_key.composite? ? (values if values.all?) : values.first

        if foreign_key_was && model_was < ActiveRecord::Base
          update_counters_via_scope(model_was, foreign_key_was, -1, match)
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
              match = reflection.association_link(klass).match
              update_counters_via_scope(klass, match.reference_key.value_of(owner), by, match)
            end
          end
        end

        def update_counters_via_scope(klass, values, by, match = reflection.association_link(klass).match)
          scope = klass.all_queries_scope.where!(match.target_key.where_hash(values))
          scope.update_counters(reflection.counter_cache_column => by, touch: reflection.options[:touch])
        end

        def find_target?
          !loaded? && foreign_key_present? && klass
        end

        def require_counter_update?
          reflection.counter_cache_column && owner.persisted?
        end

        def replace_keys(record, force: false)
          target_key_values = record ? ActiveRecord::Key.for(primary_key(record.class)).map { |col| record.read_attribute(col) } : []
          owner_key_values = foreign_key.map { |fk| owner.read_attribute(fk) }

          return if !force && owner_key_values == target_key_values

          owner_pk = ActiveRecord::Key.for(owner.class.primary_key)

          # Preserve shared primary key columns only if another foreign key
          # column can be cleared to disassociate the record.
          preserve_owner_pk = record.nil? && foreign_key.any? { |key| !owner_pk.include?(key) }

          foreign_key.each_with_index do |key, index|
            next if preserve_owner_pk && owner_pk.include?(key)
            owner.write_attribute(key, target_key_values[index])
          end
        end

        def primary_key(klass)
          reflection.association_primary_key(klass)
        end

        def foreign_key_present?
          foreign_key.all? { |fk| owner.read_attribute(fk) }
        end

        def invertible_for?(record)
          inverse = inverse_reflection_for(record)
          inverse && (inverse.has_one? || inverse.klass.has_many_inversing)
        end

        def stale_state
          values = foreign_key.map do |fk|
            owner.read_attribute(fk) { |n| owner.send(:missing_attribute, n, caller) }
          end
          foreign_key.composite? ? (values if values.any?) : values.first
        end
    end
  end
end
