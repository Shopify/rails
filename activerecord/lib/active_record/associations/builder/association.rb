# frozen_string_literal: true

# This is the parent Association class which defines the variables
# used by all associations.
#
# The hierarchy is defined as follows:
#  Association
#    - SingularAssociation
#      - BelongsToAssociation
#      - HasOneAssociation
#    - CollectionAssociation
#      - HasManyAssociation

module ActiveRecord::Associations::Builder # :nodoc:
  class Association # :nodoc:
    class << self
      attr_accessor :extensions
    end
    self.extensions = []

    VALID_OPTIONS = [
      :anonymous_class, :primary_key, :foreign_key, :dependent, :validate, :inverse_of, :strict_loading, :query_constraints, :deprecated
    ].freeze # :nodoc:
    VARIANT_INVARIANT_OPTIONS = [:dependent, :validate, :autosave, :deprecated].freeze # :nodoc:



    def self.build(model, name, scope, options, &block)
      check_name_conflict!(model, name)


      reflection = create_reflection(model, name, scope, options, &block)
      define_model_methods(model, reflection)
      reflection
    end

    def self.build_with_variants(model, name, variants, resolver)
      validate_variant_definition(model, name, variants, resolver)

      reflections = variants.transform_values do |options|
        create_reflection(model, name, nil, options.dup)
      end

      build_variant_reflection(model, name, reflections, resolver)
    end

    def self.validate_variant_definition(model, name, variants, resolver)
      check_name_conflict!(model, name)
      raise ArgumentError, "A variant resolver block is required" unless resolver
      raise ArgumentError, "At least one association variant is required" if variants.empty?

      variants.each do |variant, options|
        raise ArgumentError, "Association variant names must be Symbols" unless variant.is_a?(Symbol)
        raise ArgumentError, "Options for association variant #{variant.inspect} must be a Hash" unless options.is_a?(Hash)
      end
    end

    def self.build_variant_reflection(model, name, reflections, resolver)
      validate_variant_invariants(model, name, reflections)
      reflection = ActiveRecord::Reflection::VariantReflection.new(reflections, resolver)
      define_model_methods(model, reflections.values.first)
      synchronize_variant_invariant_options(reflections)
      reflection
    end




    def self.create_reflection(model, name, scope, options, &block)
      raise ArgumentError, "association names must be a Symbol" unless name.kind_of?(Symbol)

      validate_options(options)

      extension = define_extensions(model, name, &block)
      options[:extend] = [*options[:extend], extension] if extension

      scope = build_scope(scope)

      ActiveRecord::Reflection.create(macro, name, scope, options, model)
    end

    def self.build_scope(scope)
      if scope && scope.arity == 0
        proc { instance_exec(&scope) }
      else
        scope
      end
    end
    def self.check_name_conflict!(model, name)
      if model.dangerous_attribute_method?(name)
        raise ArgumentError, "You tried to define an association named #{name} on the model #{model.name}, but " \
                             "this will conflict with a method #{name} already defined by Active Record. " \
                             "Please choose a different association name."
      end
    end

    def self.define_model_methods(model, reflection)
      define_accessors(model, reflection)
      define_callbacks(model, reflection)
      define_validations(model, reflection)
      define_change_tracking_methods(model, reflection)
    end

    def self.variant_invariant_options
      VARIANT_INVARIANT_OPTIONS
    end

    def self.validate_variant_invariants(model, name, reflections)
      association_classes = reflections.each_value.map(&:association_class).uniq
      if association_classes.many?
        raise ArgumentError, "All variants of #{model.name}##{name} must use the same association type"
      end

      variant_invariant_options.each do |option|
        values = reflections.each_value.map { |reflection| reflection.options[option] }
        next if values.all? { |value| value == values.first }

        raise ArgumentError, "The :#{option} option must be the same for every variant of #{model.name}##{name}"
      end
    end
    def self.synchronize_variant_invariant_options(reflections)
      source_options = reflections.values.first.options

      reflections.each_value.with_index do |reflection, index|
        next if index == 0

        variant_invariant_options.each do |option|
          if source_options.key?(option)
            reflection.options[option] = source_options[option]
          else
            reflection.options.delete(option)
          end
        end
      end
    end



    def self.macro
      raise NotImplementedError
    end

    def self.valid_options(options)
      VALID_OPTIONS + Association.extensions.flat_map(&:valid_options)
    end

    def self.validate_options(options)
      options.assert_valid_keys(valid_options(options))
    end

    def self.define_extensions(model, name)
      # noop
    end

    def self.define_callbacks(model, reflection)
      if dependent = reflection.options[:dependent]
        check_dependent_options(dependent, model)
        add_destroy_callbacks(model, reflection)
        add_after_commit_jobs_callback(model, dependent)
      end

      Association.extensions.each do |extension|
        extension.build(model, reflection)
      end
    end

    # Defines the setter and getter methods for the association
    # class Post < ActiveRecord::Base
    #   has_many :comments
    # end
    #
    # Post.first.comments and Post.first.comments= methods are defined by this method...
    def self.define_accessors(model, reflection)
      mixin = model.generated_association_methods
      name = reflection.name
      define_readers(mixin, name)
      define_writers(mixin, name)
    end

    def self.define_readers(mixin, name)
      mixin.class_eval <<-CODE, __FILE__, __LINE__ + 1
        def #{name}
          association = association(:#{name})
          deprecated_associations_api_guard(association, __method__)
          association.reader
        end
      CODE
    end

    def self.define_writers(mixin, name)
      mixin.class_eval <<-CODE, __FILE__, __LINE__ + 1
        def #{name}=(value)
          association = association(:#{name})
          deprecated_associations_api_guard(association, __method__)
          association.writer(value)
        end
      CODE
    end

    def self.define_validations(model, reflection)
      # noop
    end

    def self.define_change_tracking_methods(model, reflection)
      # noop
    end

    def self.valid_dependent_options
      raise NotImplementedError
    end

    def self.check_dependent_options(dependent, model)
      if dependent == :destroy_async && !model.destroy_association_async_job
        err_message = "A valid destroy_association_async_job is required to use `dependent: :destroy_async` on associations"
        raise ActiveRecord::ConfigurationError, err_message
      end
      unless valid_dependent_options.include?(dependent)
        raise ArgumentError, "The :dependent option must be one of #{valid_dependent_options}, but is :#{dependent}"
      end
    end

    def self.add_destroy_callbacks(model, reflection)
      if reflection.deprecated?
        # If :dependent is set, destroying the record has a side effect that
        # would no longer happen if the association is removed.
        model.before_destroy do
          report_deprecated_association(reflection, context: ":dependent has a side effect here")
        end
      end

      model.before_destroy(->(o) { o.association(reflection.name).handle_dependency })
    end

    def self.add_after_commit_jobs_callback(model, dependent)
      if dependent == :destroy_async
        mixin = model.generated_association_methods

        unless mixin.method_defined?(:_after_commit_jobs)
          model.after_commit(-> do
            _after_commit_jobs.each do |job_class, job_arguments|
              job_class.perform_later(**job_arguments)
            end
          end)

          mixin.class_eval <<-CODE, __FILE__, __LINE__ + 1
            def _after_commit_jobs
              @_after_commit_jobs ||= []
            end
          CODE
        end
      end
    end

    private_class_method :build_scope, :macro, :valid_options, :validate_options, :define_extensions,
      :check_name_conflict!, :define_model_methods, :variant_invariant_options,
      :validate_variant_invariants, :synchronize_variant_invariant_options, :define_callbacks,
      :define_accessors, :define_readers, :define_writers, :define_validations,
      :define_change_tracking_methods, :valid_dependent_options, :check_dependent_options,
      :add_destroy_callbacks, :add_after_commit_jobs_callback
  end
end
