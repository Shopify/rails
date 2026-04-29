# frozen_string_literal: true

module ActiveRecord::Associations::Builder # :nodoc:
  class BelongsTo < SingularAssociation # :nodoc:
    def self.macro
      :belongs_to
    end

    def self.valid_options(options)
      valid = super + [:polymorphic, :counter_cache, :optional, :default]
      valid << :class_name unless options[:polymorphic]
      valid << :foreign_type if options[:polymorphic]
      valid << :ensuring_owner_was if options[:dependent] == :destroy_async
      valid
    end

    def self.valid_dependent_options
      [:destroy, :delete, :destroy_async]
    end

    def self.define_callbacks(model, reflection)
      super
      add_counter_cache_callbacks(model, reflection) if reflection.options[:counter_cache]
      add_touch_callbacks(model, reflection)         if reflection.options[:touch]
      add_default_callbacks(model, reflection)       if reflection.options[:default]
    end

    def self.add_counter_cache_callbacks(model, reflection)
      cache_column = reflection.counter_cache_column
      # Snapshot +reflection.name+ into a single-assignment Symbol local
      # so the +after_update+ lambda doesn't capture +reflection+ itself
      # (mutable +@klass+ / +@validated+, not shareable).
      reflection_name = reflection.name

      counter_cache_callback = lambda { |record|
        association = record.association(reflection_name)

        if association.saved_change_to_target?
          association.increment_counters
          association.decrement_counters_before_last_save
        end
      }
      counter_cache_callback.make_shareable!
      model.after_update counter_cache_callback

      klass = reflection.class_name.safe_constantize
      klass._counter_cache_columns |= [cache_column] if klass && klass.respond_to?(:_counter_cache_columns)
      model.counter_cached_association_names |= [reflection.name]
    end

    def self.touch_record(o, changes, foreign_key, name, touch) # :nodoc:
      old_foreign_id = changes[foreign_key] && changes[foreign_key].first

      if old_foreign_id
        association = o.association(name)
        reflection = association.reflection
        if reflection.polymorphic?
          foreign_type = reflection.foreign_type
          klass = changes[foreign_type] && changes[foreign_type].first || o.public_send(foreign_type)
          klass = o.class.polymorphic_class_for(klass)
        else
          klass = association.klass
        end
        primary_key = reflection.association_primary_key(klass)
        old_record = klass.find_by(primary_key => old_foreign_id)

        if old_record
          if touch != true
            old_record.touch_later(touch)
          else
            old_record.touch_later
          end
        end
      end

      record = o.public_send name
      if record && record.persisted?
        if touch != true
          record.touch_later(touch)
        else
          record.touch_later
        end
      end
    end

    def self.add_touch_callbacks(model, reflection)
      # Snapshot the reflection-derived values into freezable, single-
      # assignment locals so the generated callback lambdas don't capture
      # +reflection+ itself (mutable +@klass+ / +@validated+, not
      # shareable). +Ractor.make_shareable+ also rejects procs that close
      # over locals which may be reassigned, so each captured local must
      # be assigned exactly once before the proc is built.
      # +Array#dup+ is shallow and +Ractor.make_shareable+ deep-freezes
      # element references in place, which would freeze Strings shared
      # with the live reflection. Map+dup the elements so we capture
      # fresh frozen Strings without mutating the source-of-truth.
      foreign_key = case (raw = reflection.foreign_key)
      when Array then raw.map { |s| s.dup.freeze }.freeze
      else raw.dup.freeze
      end
      name = reflection.name
      raw_touch = reflection.options[:touch]
      touch = raw_touch.is_a?(String) ? raw_touch.dup.freeze : Ractor.make_shareable(raw_touch)
      has_counter_cache = !!reflection.counter_cache_column

      callback = lambda { |changes_method| lambda { |record|
        BelongsTo.touch_record(record, record.send(changes_method), foreign_key, name, touch)
      }.make_shareable! }

      if has_counter_cache
        touch_callback = callback.(:saved_changes)
        update_callback = lambda { |record|
          instance_exec(record, &touch_callback) unless association(name).saved_change_to_target?
        }
        update_callback.make_shareable!
        model.after_update update_callback, if: :saved_changes?
      else
        model.after_create callback.(:saved_changes), if: :saved_changes?
        model.after_update callback.(:saved_changes), if: :saved_changes?
        model.after_destroy callback.(:changes_to_save)
      end

      model.after_touch callback.(:changes_to_save)
    end

    def self.add_default_callbacks(model, reflection)
      # Snapshot the reflection-derived locals into shareable single-
      # assignment values so the +before_validation+ lambda doesn't
      # capture +reflection+ itself.
      reflection_name = reflection.name
      default_proc = reflection.options[:default]
      callback = lambda { |o|
        o.association(reflection_name).default(&default_proc)
      }
      callback.make_shareable! if default_proc.nil? || default_proc.shareable?
      model.before_validation callback
    end

    def self.add_destroy_callbacks(model, reflection)
      if reflection.deprecated?
        # If :dependent is set, destroying the record has some side effect that
        # would no longer happen if the association is removed.
        model.before_destroy do
          report_deprecated_association(reflection, context: ":dependent has a side effect here")
        end
      end

      # Snapshot +reflection.name+ so the +after_destroy+ lambda doesn't
      # capture +reflection+ itself.
      reflection_name = reflection.name
      handle_dependency_callback = lambda { |o| o.association(reflection_name).handle_dependency }
      handle_dependency_callback.make_shareable!
      model.after_destroy handle_dependency_callback
    end

    def self.define_validations(model, reflection)
      if reflection.options.key?(:required)
        reflection.options[:optional] = !reflection.options.delete(:required)
      end

      if reflection.options[:optional].nil?
        required = model.belongs_to_required_by_default
      else
        required = !reflection.options[:optional]
      end

      super

      if required
        if ActiveRecord.belongs_to_required_validates_foreign_key
          model.validates_presence_of reflection.name, message: :required
        else
          # Snapshot the reflection-derived values into freezable locals so
          # the +if:+ condition lambda doesn't capture +reflection+ itself
          # (which holds mutable +@klass+ / +@validated+ ivars and is not
          # shareable). +foreign_key+ may be a String or Array of Strings;
          # +foreign_type+ is a String or +nil+; +polymorphic+ is a bool.
          # All freezable, so the resulting lambda is shareable. Locals
          # used inside the lambda must each be assigned exactly once
          # before capture (single-assignment), otherwise
          # +Ractor.make_shareable+ rejects the proc with "may be
          # reassigned". That's why we materialize +_foreign_type+ via
          # +Ractor.make_shareable+ rather than a guarded +.dup.freeze+.
          # +Array#dup+ is shallow and +Ractor.make_shareable+ deep-
          # freezes element references in place, which would freeze
          # Strings shared with the live reflection. Map+dup the
          # elements so we capture fresh frozen Strings without
          # mutating the source-of-truth.
          captured_foreign_key = case (raw_fk = reflection.foreign_key)
          when Array then raw_fk.map { |s| s.dup.freeze }.freeze
          else raw_fk.dup.freeze
          end
          raw_ft = reflection.foreign_type
          captured_foreign_type = raw_ft ? raw_ft.dup.freeze : nil
          captured_polymorphic = reflection.polymorphic?

          condition = lambda { |record|
            fk_missing_or_changed = if captured_foreign_key.is_a?(Array)
              captured_foreign_key.any? { |fk| record.read_attribute(fk).nil? || record.attribute_changed?(fk) }
            else
              record.read_attribute(captured_foreign_key).nil? ||
                record.attribute_changed?(captured_foreign_key)
            end

            fk_missing_or_changed ||
              (captured_polymorphic && (record.read_attribute(captured_foreign_type).nil? || record.attribute_changed?(captured_foreign_type)))
          }
          condition.make_shareable!

          model.validates_presence_of reflection.name, message: :required, if: condition
        end
      end
    end

    def self.define_change_tracking_methods(model, reflection)
      model.generated_association_methods.class_eval <<-CODE, __FILE__, __LINE__ + 1
        def #{reflection.name}_changed?
          association = association(:#{reflection.name})
          deprecated_associations_api_guard(association, __method__)
          association.target_changed?
        end

        def #{reflection.name}_previously_changed?
          association = association(:#{reflection.name})
          deprecated_associations_api_guard(association, __method__)
          association.target_previously_changed?
        end
      CODE
    end

    private_class_method :macro, :valid_options, :valid_dependent_options, :define_callbacks,
      :define_validations, :define_change_tracking_methods, :add_counter_cache_callbacks,
      :add_touch_callbacks, :add_default_callbacks, :add_destroy_callbacks
  end
end
