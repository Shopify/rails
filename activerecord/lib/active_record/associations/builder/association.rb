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

    def self.build(model, name, scope, options, &block)
      if model.dangerous_attribute_method?(name)
        raise ArgumentError, "You tried to define an association named #{name} on the model #{model.name}, but " \
                             "this will conflict with a method #{name} already defined by Active Record. " \
                             "Please choose a different association name."
      end

      reflection = create_reflection(model, name, scope, options, &block)
      define_accessors(model, reflection)
      define_callbacks(model, reflection)
      define_validations(model, reflection)
      define_change_tracking_methods(model, reflection)
      reflection
    end

    # The options that may differ between the variants of a single association.
    #
    # This is deliberately limited to the columns an association joins on, which is
    # what runtime variants exist for. Everything else is declared once for the
    # association as a whole: options that install callbacks, validations, or methods
    # on the model are applied at definition time from the abstract reflection and so
    # cannot vary per record, and keeping the target class shared is what lets
    # counter caches and +inverse_of+ continue to reason about one relationship.
    #
    # Widening this list stays backward compatible; narrowing it does not.
    VARIANT_OPTIONS = [
      :primary_key, :foreign_key, :query_constraints
    ].freeze # :nodoc:

    def self.build_with_variants(model, name, scope, options, variant_selector)
      variants = options.delete(:variants)
      validate_variants(model, name, variants, options, variant_selector)

      # One concrete reflection per variant, each built exactly like an ordinary
      # association's. Options are checked here, so a variant naming an option that
      # does not exist fails at definition time; the rest of the validation is as lazy
      # as it is for any association, and happens when the variant is first selected.
      variant_reflections = variants.to_h do |variant_name, variant_options|
        variant_reflection = create_reflection(model, name, scope, options.merge(variant_options))
        variant_reflection.declare_variant_name(variant_name)
        [variant_name, variant_reflection]
      end.freeze

      # The abstract reflection carries only the shared options, so every model
      # method and callback generated from it below holds for all variants.
      reflection = build(model, name, scope, options)
      reflection.declare_variants(variant_reflections, variant_selector)
      reflection
    end

    def self.validate_variants(model, name, variants, options, variant_selector)
      unless variant_selector
        raise ArgumentError, "#{model.name}##{name} requires a block returning the name of the active variant"
      end

      unless variants.is_a?(Hash) && !variants.empty?
        raise ArgumentError, "#{model.name}##{name} requires a `variants:` Hash naming at least one variant"
      end

      if options[:through]
        raise ArgumentError, "#{model.name}##{name} cannot combine `:through` with `variants:`, because only " \
                             "the first reflection of a through chain would resolve per variant"
      end

      variants.each do |variant_name, variant_options|
        unless variant_name.is_a?(Symbol)
          raise ArgumentError, "Variant names of #{model.name}##{name} must be Symbols, got #{variant_name.inspect}"
        end

        unless variant_options.is_a?(Hash)
          raise ArgumentError, "Options for variant #{variant_name.inspect} of #{model.name}##{name} must be a Hash"
        end

        shared_only = variant_options.keys - VARIANT_OPTIONS
        if shared_only.any?
          raise ArgumentError, "#{shared_only.map(&:inspect).join(", ")} cannot differ between the variants of " \
                               "#{model.name}##{name}. Declare #{shared_only.one? ? "it" : "them"} on the " \
                               "association itself, alongside `variants:`. Variants may only differ in " \
                               "#{VARIANT_OPTIONS.map(&:inspect).join(", ")}."
        end
      end
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

    private_class_method :build_scope, :macro, :valid_options, :validate_options, :validate_variants,
      :define_extensions,
      :define_callbacks, :define_accessors, :define_readers, :define_writers, :define_validations,
      :define_change_tracking_methods, :valid_dependent_options, :check_dependent_options,
      :add_destroy_callbacks, :add_after_commit_jobs_callback
  end
end
