# frozen_string_literal: true

module ActiveRecord
  module Reflection
    # Shared behavior for context-aware reflection proxies. Included in
    # type-specific subclasses (ContextAwareBelongsToReflection, etc.) so
    # that each proxy IS-A its wrapped reflection type and passes is_a? checks.
    #
    # A context-aware reflection wraps a default reflection and zero or more
    # context-specific overrides. Method calls resolve to the correct underlying
    # reflection based on the model's current schema context at call time.
    #
    # This ensures that cached references (e.g., inverse_of, autosave callbacks)
    # captured at class load time always resolve correctly at runtime.
    module ContextAwareness
      attr_reader :default_reflection

      def context_aware?
        true
      end

      def add_context(context_key, reflection)
        @context_reflections[context_key.to_s] = reflection
      end

      # Returns the reflection for the current schema context,
      # falling back to the default reflection.
      def current_reflection
        context_key = active_record.current_schema_context
        @context_reflections[context_key] || @default_reflection
      end

      # Returns the reflection for a specific context key.
      def reflection_for(context_key)
        @context_reflections[context_key.to_s] || @default_reflection
      end

      private
        def initialize_context_awareness(default_reflection)
          @default_reflection = default_reflection
          @context_reflections = {}
        end

        # Generates delegation methods for the given method names.
        # Each generated method forwards to current_reflection.
        def self.delegate_to_current_reflection(*method_names)
          method_names.each do |method_name|
            define_method(method_name) do |*args, **kwargs, &block|
              current_reflection.public_send(method_name, *args, **kwargs, &block)
            end
          end
        end

        delegate_to_current_reflection(
          :through_reflection?,
          :table_name,
          :build_association,
          :class_name,
          :scopes,
          :join_scope,
          :join_scopes,
          :klass_join_scope,
          :constraints,
          :counter_cache_column,
          :inverse_of,
          :check_validity_of_inverse!,
          :inverse_which_updates_counter_cache,
          :inverse_updates_counter_cache?,
          :inverse_updates_counter_in_memory?,
          :has_cached_counter?,
          :has_active_cached_counter?,
          :counter_must_be_updated_by_has_many?,
          :alias_candidate,
          :chain,
          :build_scope,
          :strict_loading?,
          :strict_loading_violation_message,
        )

        delegate_to_current_reflection(
          :scope,
          :options,
          :plural_name,
          :klass,
          :_klass,
          :compute_class,
          :scope_for,
        )

        def autosave=(autosave)
          current_reflection.autosave = autosave
        end

        delegate_to_current_reflection(
          :type,
          :foreign_type,
          :parent_reflection,
          :association_scope_cache,
          :join_table,
          :foreign_key,
          :association_foreign_key,
          :association_primary_key,
          :active_record_primary_key,
          :join_primary_key,
          :join_primary_type,
          :join_foreign_key,
          :check_validity!,
          :check_eager_loadable!,
          :join_id_for,
          :through_reflection,
          :source_reflection,
          :collect_join_chain,
          :clear_association_scope_cache,
          :nested?,
          :has_scope?,
          :has_inverse?,
          :polymorphic_inverse_of,
          :macro,
          :collection?,
          :validate?,
          :belongs_to?,
          :has_one?,
          :association_class,
          :polymorphic?,
          :polymorphic_name,
          :add_as_source,
          :add_as_polymorphic_through,
          :add_as_through,
          :extensions,
          :deprecated?,
        )

        def parent_reflection=(reflection)
          current_reflection.parent_reflection = reflection
        end
    end

    class ContextAwareBelongsToReflection < BelongsToReflection # :nodoc:
      include ContextAwareness

      def initialize(default_reflection)
        initialize_context_awareness(default_reflection)
        super(default_reflection.name, default_reflection.scope, default_reflection.options.dup, default_reflection.active_record)
      end

      # BelongsToReflection-specific method
      def join_foreign_type
        current_reflection.join_foreign_type
      end
    end

    class ContextAwareHasManyReflection < HasManyReflection # :nodoc:
      include ContextAwareness

      def initialize(default_reflection)
        initialize_context_awareness(default_reflection)
        super(default_reflection.name, default_reflection.scope, default_reflection.options.dup, default_reflection.active_record)
      end
    end

    class ContextAwareHasOneReflection < HasOneReflection # :nodoc:
      include ContextAwareness

      def initialize(default_reflection)
        initialize_context_awareness(default_reflection)
        super(default_reflection.name, default_reflection.scope, default_reflection.options.dup, default_reflection.active_record)
      end
    end
  end
end
