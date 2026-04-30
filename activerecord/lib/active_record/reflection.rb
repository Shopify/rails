# frozen_string_literal: true

require "active_support/core_ext/string/filters"

module ActiveRecord
  # = Active Record Reflection
  module Reflection # :nodoc:
    extend ActiveSupport::Concern

    included do
      class_attribute :_reflections, instance_writer: false, default: {}
      class_attribute :aggregate_reflections, instance_writer: false, default: {}
      class_attribute :automatic_scope_inversing, instance_writer: false, default: false
      class_attribute :automatically_invert_plural_associations, instance_writer: false, default: false
    end

    class << self
      def create(macro, name, scope, options, ar)
        reflection = reflection_class_for(macro).new(name, scope, options, ar)
        options[:through] ? ThroughReflection.new(reflection) : reflection
      end

      def add_reflection(ar, name, reflection)
        ar.clear_reflections_cache
        name = name.to_sym
        ar._reflections = ar._reflections.except(name).merge!(name => reflection)
      end

      def add_aggregate_reflection(ar, name, reflection)
        ar.aggregate_reflections = ar.aggregate_reflections.merge(name.to_sym => reflection)
      end

      private
        def reflection_class_for(macro)
          case macro
          when :composed_of
            AggregateReflection
          when :has_many
            HasManyReflection
          when :has_one
            HasOneReflection
          when :belongs_to
            BelongsToReflection
          else
            raise "Unsupported Macro: #{macro}"
          end
        end
    end

    # = Active Record Reflection
    #
    # \Reflection enables the ability to examine the associations and aggregations of
    # Active Record classes and objects. This information, for example,
    # can be used in a form builder that takes an Active Record object
    # and creates input fields for all of the attributes depending on their type
    # and displays the associations to other objects.
    #
    # MacroReflection class has info for AggregateReflection and AssociationReflection
    # classes.
    module ClassMethods
      # Returns an array of AggregateReflection objects for all the aggregations in the class.
      def reflect_on_all_aggregations
        aggregate_reflections.values
      end

      # Returns the AggregateReflection object for the named +aggregation+ (use the symbol).
      #
      #   Account.reflect_on_aggregation(:balance) # => the balance AggregateReflection
      #
      def reflect_on_aggregation(aggregation)
        if !Ractor.main? && defined?(@__shareable_aggregate_reflections) && @__shareable_aggregate_reflections
          @__shareable_aggregate_reflections[aggregation.to_sym]
        else
          aggregate_reflections[aggregation.to_sym]
        end
      end

      # Returns a Hash of name of the reflection as the key and an AssociationReflection as the value.
      #
      #   Account.reflections # => {"balance" => AggregateReflection}
      #
      def reflections
        normalized_reflections.stringify_keys
      end

      def normalized_reflections # :nodoc:
        # Non-main reads use the sanitized, shareable copy snapshotted at boot
        # by +make_reflections_shareable!+. The lazy +@__reflections+ memoize
        # below is a class ivar write — disallowed from non-main Ractors.
        if !Ractor.main? && defined?(@__shareable_normalized_reflections) && @__shareable_normalized_reflections
          return @__shareable_normalized_reflections
        end

        @__reflections ||= begin
          ref = {}

          _reflections.each do |name, reflection|
            parent_reflection = reflection.parent_reflection

            if parent_reflection
              parent_name = parent_reflection.name
              ref[parent_name] = parent_reflection
            else
              ref[name] = reflection
            end
          end

          ref.freeze
        end
      end

      # Returns an array of AssociationReflection objects for all the
      # associations in the class. If you only want to reflect on a certain
      # association type, pass in the symbol (<tt>:has_many</tt>, <tt>:has_one</tt>,
      # <tt>:belongs_to</tt>) as the first parameter.
      #
      # Example:
      #
      #   Account.reflect_on_all_associations             # returns an array of all associations
      #   Account.reflect_on_all_associations(:has_many)  # returns an array of all has_many associations
      #
      def reflect_on_all_associations(macro = nil)
        association_reflections = normalized_reflections.values
        association_reflections.select! { |reflection| reflection.macro == macro } if macro
        association_reflections
      end

      # Returns the AssociationReflection object for the +association+ (use the symbol).
      #
      #   Account.reflect_on_association(:owner)             # returns the owner AssociationReflection
      #   Invoice.reflect_on_association(:line_items).macro  # returns :has_many
      #
      def reflect_on_association(association)
        normalized_reflections[association.to_sym]
      end

      def _reflect_on_association(association) # :nodoc:
        # On non-main Ractors the live +_reflections+ Hash is unreachable
        # (its values are full Reflection objects whose +@scope+ Procs aren't
        # shareable). +make_reflections_shareable!+ snapshots a sanitized,
        # deep-frozen copy onto +@__shareable_reflections+ at boot; read from
        # that copy here so callers (predicate_builder, table_metadata, etc.)
        # see the same metadata they would on main.
        if !Ractor.main? && defined?(@__shareable_reflections) && @__shareable_reflections
          @__shareable_reflections[association.to_sym]
        else
          _reflections[association.to_sym]
        end
      end

      # Returns an array of AssociationReflection objects for all associations which have <tt>:autosave</tt> enabled.
      def reflect_on_all_autosave_associations
        reflections = normalized_reflections.values
        reflections.select! { |reflection| reflection.options[:autosave] }
        reflections
      end

      def clear_reflections_cache # :nodoc:
        @__reflections = nil
      end

      # Force-resolve every lazy memo on every Reflection stored under this
      # AR class's +_reflections+ / +aggregate_reflections+ class_attribute,
      # then replace those Hashes with deep-frozen, shareable copies and
      # warm the +@__reflections+ normalized cache to the frozen version.
      #
      # +PredicateBuilder#expand_from_hash+ calls
      # +TableMetadata#associated_with(key)+ for every key in a +where(...)+
      # Hash, including plain column keys. That reads
      # +_reflections+ off the class_attribute ivar, which raises
      # +Ractor::IsolationError+ from a non-main Ractor until the Hash and
      # every Reflection inside it are shareable. The owner of the
      # +_reflections+ Hash is each AR descendant that calls +has_many+ /
      # +belongs_to+ / +has_one+ / +composed_of+, so the warmer lives here in
      # +Reflection::ClassMethods+.
      #
      # In production, associations are declared at class-definition time and
      # not added afterwards. The lazy memos on each Reflection (+@class_name+,
      # +@inverse_of+, +@klass+, +@foreign_key+, etc.) are likewise resolved
      # once and never recomputed. Pre-warming them before deep-freezing means
      # subsequent calls on either Ractor return the cached value instead of
      # attempting to re-memoize on a frozen object.
      def make_reflections_shareable! # :nodoc:
        return if defined?(@__reflections_shareable) && @__reflections_shareable

        # Force-resolve memos on each MacroReflection / AssociationReflection.
        # +_reflections+ holds the user-declared associations; for HABTM and
        # +through:+ reflections, +parent_reflection+ may also expose memos
        # that haven't been touched yet, so warm those too via the normalized
        # cache pass below.
        _reflections.each_value do |reflection|
          warm_reflection_memos(reflection)
        end
        aggregate_reflections.each_value do |reflection|
          warm_reflection_memos(reflection)
        end

        # +ThroughReflection+ exposes +source_reflection+ / +through_reflection+
        # which may walk back into +_reflections+ on +through_reflection.klass+.
        # Force the normalized cache so +@__reflections+ is populated and
        # frozen-shareable too.
        normalized = {}
        _reflections.each do |name, reflection|
          parent = reflection.parent_reflection
          if parent
            warm_reflection_memos(parent)
            normalized[parent.name] = parent
          else
            normalized[name] = reflection
          end
        end

        # Build sanitized, shareable copies of each reflection. The live
        # +@scope+ on associations is a Proc that may capture per-class state
        # (e.g. +has_one_attached+ produces +-> { where(name: name) }+, and
        # +Builder::Association.build_scope+ wraps zero-arity scopes in
        # +proc { instance_exec(&scope) }+). Those Procs aren't shareable, so
        # we deep-clone each reflection, replace +@scope+ with +nil+ on the
        # clone, then deep-freeze the clone via +make_shareable(copy: true)+.
        # The main-Ractor scope-evaluation paths (+scope_for+,
        # +has_scope?+, etc.) still read the LIVE +_reflections+ Hash so the
        # framework's mutation paths (+CounterCache#load_schema!+ memoization,
        # +autosave=+, +parent_reflection=+, etc.) keep working untouched.
        # Non-main reads route through +_reflect_on_association+ /
        # +reflect_on_aggregation+, which consult these shadow ivars instead
        # of the unshareable live Hashes.
        @__shareable_reflections = build_shareable_reflection_hash(_reflections)
        @__shareable_aggregate_reflections = build_shareable_reflection_hash(aggregate_reflections)
        @__shareable_normalized_reflections = build_shareable_reflection_hash(normalized)

        @__reflections_shareable = true
      end

      private
        def build_shareable_reflection_hash(source)
          shareable = source.transform_values(&:shareable_clone)
          Ractor.make_shareable(shareable, copy: true)
        end

        def warm_reflection_memos(reflection)
          # Skip if already warmed (idempotent across descendant walks).
          return if reflection.frozen?

          # +AssociationReflection#check_validity!+ memoizes +@validated+
          # on first read and is called from +Association#initialize+ on
          # every +record.association(name)+ call. From a non-main Ractor
          # the dispatched +association(...)+ would otherwise reach a
          # frozen shareable_clone with +@validated=false+ and raise
          # +FrozenError+. Resolve it here so both the live reflection
          # and the clone start out validated. Skip aggregate reflections
          # (no +check_validity!+) and only call when the reflection's
          # context is resolvable (has +klass+ for non-polymorphic).
          # +ThroughReflection+ inherits from +AbstractReflection+ directly
          # (not from +AssociationReflection+), but defines its own
          # +check_validity!+ — include it explicitly.
          if reflection.is_a?(AssociationReflection) || reflection.is_a?(ThroughReflection)
            begin
              reflection.check_validity!
            rescue NameError, ActiveRecord::AssociationNotFoundError => e
              # An association whose target class can't be resolved at boot
              # (e.g., polymorphic with no instance referencing it yet, or
              # a model that hasn't been autoloaded) cannot be validated
              # here. Skip the warm — the runtime path will surface the same
              # error on first non-warmed access. Log so the skipped warm
              # stays visible.
              Rails.logger&.warn("warm_reflection_memos: check_validity! skipped for #{inspect}.#{reflection.name}: #{e.class}: #{e.message}")
            end
          end

          # +class_name+ memoizes +@class_name+. Skip when polymorphic — the
          # association doesn't have a single resolvable class name and
          # +derive_class_name+ would still set the memo to the literal name,
          # which we don't want for a polymorphic association. Aggregate
          # reflections don't define +polymorphic?+, so test responsively.
          if !(reflection.respond_to?(:polymorphic?) && reflection.polymorphic?)
            reflection.class_name
          end

          # +ThroughReflection+ memoizes +@source_reflection_name+ via the
          # private +source_reflection_name+, and +@deprecated_nested_reflections+
          # via +deprecated_nested_reflections+ (called from the preloader
          # branch). Warm only on ThroughReflection (the only class that
          # defines memoized versions; the abstract +through_reflection?+
          # predicate identifies it).
          if reflection.through_reflection?
            reflection.send(:source_reflection_name)
            reflection.deprecated_nested_reflections
          end

          # AssociationReflection-specific lazy memos (foreign keys, inverses,
          # counter caches). Skipped for AggregateReflection (which doesn't
          # define them). +ThroughReflection+ delegates these to its
          # +@delegate_reflection+ — the delegate is a HasMany / HasOne /
          # BelongsTo reflection that is NOT in +_reflections+ on its own
          # (only the ThroughReflection wrapping it is), so reaching it
          # through the through-reflection here is the only way to warm
          # the delegate's +@inverse_name+ etc. before the deep-freeze.
          if reflection.is_a?(AssociationReflection) || reflection.is_a?(ThroughReflection)
            reflection.foreign_key
            reflection.active_record_primary_key
            reflection.counter_cache_column
            reflection.has_inverse?
            unless reflection.polymorphic?
              # +association_foreign_key+, +join_table+ (via
              # +derive_join_table+), +inverse_of+, and
              # +inverse_which_updates_counter_cache+ all eventually need
              # +klass+ — which raises ArgumentError on polymorphic
              # associations. The reflection still reads cleanly from non-main
              # Ractors without these memos warmed because +polymorphic?+
              # short-circuits the relevant code paths.
              reflection.association_foreign_key
              reflection.join_table
              reflection.inverse_of
              reflection.inverse_which_updates_counter_cache
            end
          end
        end

        def inherited(subclass)
          super
          subclass.class_eval do
            @__reflections = nil
          end
        end
    end

    # Holds all the methods that are shared between MacroReflection and ThroughReflection.
    #
    #   AbstractReflection
    #     MacroReflection
    #       AggregateReflection
    #       AssociationReflection
    #         HasManyReflection
    #         HasOneReflection
    #         BelongsToReflection
    #         HasAndBelongsToManyReflection
    #     ThroughReflection
    #     PolymorphicReflection
    #     RuntimeReflection
    class AbstractReflection # :nodoc:
      def initialize
        @class_name = nil
        @counter_cache_column = nil
        @inverse_of = nil
        @inverse_which_updates_counter_cache_defined = false
        @inverse_which_updates_counter_cache = nil
      end

      def through_reflection?
        false
      end

      def table_name
        klass.table_name
      end

      # Returns a new, unsaved instance of the associated class. +attributes+ will
      # be passed to the class's constructor.
      def build_association(attributes, &block)
        klass.new(attributes, &block)
      end

      # Returns the class name for the macro.
      #
      # <tt>composed_of :balance, class_name: 'Money'</tt> returns <tt>'Money'</tt>
      # <tt>has_many :clients</tt> returns <tt>'Client'</tt>
      def class_name
        @class_name ||= -(options[:class_name] || derive_class_name).to_s
      end

      # Returns a list of scopes that should be applied for this Reflection
      # object when querying the database.
      def scopes
        scope ? [scope] : []
      end

      def join_scope(table, foreign_table, foreign_klass)
        predicate_builder = klass.predicate_builder.with(TableMetadata.new(klass, table))
        scope_chain_items = join_scopes(table, predicate_builder)
        klass_scope       = klass_join_scope(table, predicate_builder)

        if type
          klass_scope.where!(type => foreign_klass.polymorphic_name)
        end

        scope_chain_items.inject(klass_scope, &:merge!)

        primary_key_column_names = Array(join_primary_key)
        foreign_key_column_names = Array(join_foreign_key)

        primary_foreign_key_pairs = primary_key_column_names.zip(foreign_key_column_names)

        primary_foreign_key_pairs.each do |primary_key_column_name, foreign_key_column_name|
          klass_scope.where!(table[primary_key_column_name].eq(foreign_table[foreign_key_column_name]))
        end

        if klass.finder_needs_type_condition?
          klass_scope.where!(klass.send(:type_condition, table))
        end

        klass_scope
      end

      def join_scopes(table, predicate_builder = nil, klass = self.klass, record = nil) # :nodoc:
        if scope
          [scope_for(build_scope(table, predicate_builder, klass), record)]
        else
          []
        end
      end

      def klass_join_scope(table, predicate_builder = nil) # :nodoc:
        relation = build_scope(table, predicate_builder)
        klass.scope_for_association(relation)
      end

      def constraints
        chain.flat_map(&:scopes)
      end

      def counter_cache_column
        @counter_cache_column ||= begin
          counter_cache = options[:counter_cache]

          if belongs_to?
            if counter_cache
              counter_cache[:column] || -"#{active_record.name.demodulize.underscore.pluralize}_count"
            end
          else
            -((counter_cache && -counter_cache[:column]) || "#{name}_count")
          end
        end
      end

      def inverse_of
        return unless inverse_name

        @inverse_of ||= klass._reflect_on_association inverse_name
      end

      def check_validity_of_inverse!
        if !polymorphic? && has_inverse?
          if inverse_of.nil?
            raise InverseOfAssociationNotFoundError.new(self)
          end
          if inverse_of == self
            raise InverseOfAssociationRecursiveError.new(self)
          end
        end
      end

      # We need to avoid the following situation:
      #
      #   * An associated record is deleted via record.destroy
      #   * Hence the callbacks run, and they find a belongs_to on the record with a
      #     :counter_cache options which points back at our owner. So they update the
      #     counter cache.
      #   * In which case, we must make sure to *not* update the counter cache, or else
      #     it will be decremented twice.
      #
      # Hence this method.
      def inverse_which_updates_counter_cache
        unless @inverse_which_updates_counter_cache_defined
          if counter_cache_column
            inverse_candidates = inverse_of ? [inverse_of] : klass.reflect_on_all_associations(:belongs_to)
            @inverse_which_updates_counter_cache = inverse_candidates.find do |inverse|
              inverse.counter_cache_column == counter_cache_column && (inverse.polymorphic? || inverse.klass == active_record)
            end
          end
          @inverse_which_updates_counter_cache_defined = true
        end
        @inverse_which_updates_counter_cache
      end
      alias inverse_updates_counter_cache? inverse_which_updates_counter_cache

      def inverse_updates_counter_in_memory?
        inverse_of && inverse_which_updates_counter_cache == inverse_of
      end

      # Returns whether this association has a counter cache.
      #
      # The counter_cache option must be given on either the owner or inverse
      # association, and the column must be present on the owner.
      def has_cached_counter?
        options[:counter_cache] ||
          inverse_which_updates_counter_cache && inverse_which_updates_counter_cache.options[:counter_cache] &&
          active_record.has_attribute?(counter_cache_column)
      end

      # Returns whether this association has a counter cache and its column values were backfilled
      # (and so it is used internally by methods like +size+/+any?+/etc).
      def has_active_cached_counter?
        return false unless has_cached_counter?

        counter_cache = options[:counter_cache] ||
                        (inverse_which_updates_counter_cache && inverse_which_updates_counter_cache.options[:counter_cache])

        counter_cache[:active] != false
      end

      def counter_must_be_updated_by_has_many?
        !inverse_updates_counter_in_memory? && has_cached_counter?
      end

      def alias_candidate(name)
        "#{plural_name}_#{name}"
      end

      def chain
        collect_join_chain
      end

      def build_scope(table, predicate_builder = nil, klass = self.klass)
        Relation.create(klass, table:, predicate_builder:)
      end

      def strict_loading?
        options[:strict_loading]
      end

      def strict_loading_violation_message(owner)
        message = +"`#{owner}` is marked for strict_loading."
        message << " The #{polymorphic? ? "polymorphic association" : "#{klass} association"}"
        message << " named `:#{name}` cannot be lazily loaded."
      end

      # Build a sanitized clone suitable for use inside a frozen, shareable
      # +_reflections+ Hash on a non-main Ractor read path. The clone drops
      # the live +@scope+ Proc and any +options[:extend]+ Procs (which can
      # capture per-class state and aren't shareable), then recursively
      # sanitizes any nested reflection (delegate / parent). The original
      # +self+ is left untouched so main-Ractor scope evaluation continues
      # to use the live, mutable graph the framework wired into association
      # callbacks.
      def shareable_clone # :nodoc:
        sanitized = clone
        sanitized.send(:strip_unshareable_state!)
        sanitized
      end

      protected
        def actual_source_reflection # FIXME: this is a horrible name
          self
        end

        # Subclasses override to recursively sanitize nested reflections.
        # The base implementation handles +@scope+ and +options[:extend]+,
        # which is sufficient for non-Through reflection types.
        def strip_unshareable_state!
          if instance_variable_defined?(:@scope) && instance_variable_get(:@scope)
            instance_variable_set(:@scope, nil)
          end
          if instance_variable_defined?(:@options)
            options = instance_variable_get(:@options)
            if options.is_a?(Hash) && options.key?(:extend)
              instance_variable_set(:@options, options.except(:extend))
            end
          end
        end

      private
        def primary_key(klass)
          klass.primary_key || raise(UnknownPrimaryKey.new(klass))
        end

        def ensure_option_not_given_as_class!(option_name)
          if options[option_name] && options[option_name].class == Class
            raise ArgumentError, "A class was passed to `:#{option_name}` but we are expecting a string."
          end
        end
    end

    # Base class for AggregateReflection and AssociationReflection. Objects of
    # AggregateReflection and AssociationReflection are returned by the Reflection::ClassMethods.
    class MacroReflection < AbstractReflection
      # Returns the name of the macro.
      #
      # <tt>composed_of :balance, class_name: 'Money'</tt> returns <tt>:balance</tt>
      # <tt>has_many :clients</tt> returns <tt>:clients</tt>
      attr_reader :name

      attr_reader :scope

      # Returns the hash of options used for the macro.
      #
      # <tt>composed_of :balance, class_name: 'Money'</tt> returns <tt>{ class_name: "Money" }</tt>
      # <tt>has_many :clients</tt> returns <tt>{}</tt>
      attr_reader :options

      attr_reader :active_record

      attr_reader :plural_name # :nodoc:

      def initialize(name, scope, options, active_record)
        super()
        @name          = name
        @scope         = scope
        @options       = normalize_options(options)
        @active_record = active_record
        @klass         = options[:anonymous_class]
        @plural_name   = active_record.pluralize_table_names ?
                            name.to_s.pluralize : name.to_s
      end

      def autosave=(autosave)
        @options[:autosave] = autosave
        parent_reflection = self.parent_reflection
        if parent_reflection
          parent_reflection.autosave = autosave
        end
      end

      # Returns the class for the macro.
      #
      # <tt>composed_of :balance, class_name: 'Money'</tt> returns the Money class
      # <tt>has_many :clients</tt> returns the Client class
      #
      #   class Company < ActiveRecord::Base
      #     has_many :clients
      #   end
      #
      #   Company.reflect_on_association(:clients).klass
      #   # => Client
      #
      # <b>Note:</b> Do not call +klass.new+ or +klass.create+ to instantiate
      # a new association object. Use +build_association+ or +create_association+
      # instead. This allows plugins to hook into association object creation.
      def klass
        @klass ||= _klass(class_name)
      end

      def _klass(class_name) # :nodoc:
        if active_record.name.demodulize == class_name
          begin
            return compute_class("::#{class_name}")
          rescue
            # Ignored
          end
        end

        compute_class(class_name)
      end

      def compute_class(name)
        name.constantize
      end

      # Returns +true+ if +self+ and +other_aggregation+ have the same +name+ attribute, +active_record+ attribute,
      # and +other_aggregation+ has an options hash assigned to it.
      def ==(other_aggregation)
        super ||
          other_aggregation.kind_of?(self.class) &&
          name == other_aggregation.name &&
          !other_aggregation.options.nil? &&
          active_record == other_aggregation.active_record
      end

      def scope_for(relation, owner = nil)
        relation.instance_exec(owner, &scope) || relation
      end

      private
        def derive_class_name
          name.to_s.camelize
        end

        def normalize_options(options)
          counter_cache = options.delete(:counter_cache)

          if counter_cache
            active = true

            case counter_cache
            when String, Symbol
              column = -counter_cache.to_s
            when Hash
              active = counter_cache.fetch(:active, true)
              column = counter_cache[:column]&.to_s
            end

            options[:counter_cache] = { active: active, column: column }
          end

          options
        end
    end

    # Holds all the metadata about an aggregation as it was specified in the
    # Active Record class.
    class AggregateReflection < MacroReflection # :nodoc:
      def mapping
        mapping = options[:mapping] || [name, name]
        mapping.first.is_a?(Array) ? mapping : [mapping]
      end
    end

    # Holds all the metadata about an association as it was specified in the
    # Active Record class.
    class AssociationReflection < MacroReflection # :nodoc:
      def compute_class(name)
        if polymorphic?
          raise ArgumentError, "Polymorphic associations do not support computing the class."
        end

        begin
          klass = active_record.send(:compute_type, name)
        rescue NameError => error
          if error.name.match?(/(?:\A|::)#{name}\z/)
            message = "Missing model class #{name} for the #{active_record}##{self.name} association."
            message += " You can specify a different model class with the :class_name option." unless options[:class_name]
            raise NameError.new(message, name)
          else
            raise
          end
        end

        unless klass < ActiveRecord::Base
          raise ArgumentError, "The #{name} model class for the #{active_record}##{self.name} association is not an ActiveRecord::Base subclass."
        end

        klass
      end

      attr_reader :type, :foreign_type
      attr_accessor :parent_reflection # Reflection

      def initialize(name, scope, options, active_record)
        super

        @validated = false
        @type = -(options[:foreign_type]&.to_s || "#{options[:as]}_type") if options[:as]
        @foreign_type = -(options[:foreign_type]&.to_s || "#{name}_type") if options[:polymorphic]
        @join_table = nil
        @foreign_key = nil
        @association_foreign_key = nil
        @association_primary_key = nil
        if options[:query_constraints]
          raise ConfigurationError, <<~MSG.squish
            Setting `query_constraints:` option on `#{active_record}.#{macro} :#{name}` is not allowed.
            To get the same behavior, use the `foreign_key` option instead.
          MSG
        end

        # If the foreign key is an array, set query constraints options and don't use the foreign key
        if options[:foreign_key].is_a?(Array)
          options[:query_constraints] = options.delete(:foreign_key)
        end

        @deprecated = !!options[:deprecated]

        ensure_option_not_given_as_class!(:class_name)
      end

      def association_scope_cache(klass, owner, &block)
        key = self
        if polymorphic?
          key = [key, owner._read_attribute(@foreign_type)]
        end
        klass.with_connection do |connection|
          klass.cached_find_by_statement(connection, key, &block)
        end
      end

      def join_table
        @join_table ||= -(options[:join_table]&.to_s || derive_join_table)
      end

      def foreign_key(infer_from_inverse_of: true)
        @foreign_key ||= if options[:foreign_key]
          if options[:foreign_key].is_a?(Array)
            options[:foreign_key].map { |fk| -fk.to_s.freeze }.freeze
          else
            options[:foreign_key].to_s.freeze
          end
        elsif options[:query_constraints]
          options[:query_constraints].map { |fk| -fk.to_s.freeze }.freeze
        else
          derived_fk = derive_foreign_key(infer_from_inverse_of: infer_from_inverse_of)

          if !derived_fk.is_a?(Array) && active_record.has_query_constraints?
            derived_fk = derive_fk_query_constraints(derived_fk)
          end

          if derived_fk.is_a?(Array)
            derived_fk.map { |fk| -fk.freeze }.freeze
          else
            -derived_fk.freeze
          end
        end
      end

      def association_foreign_key
        @association_foreign_key ||= -(options[:association_foreign_key]&.to_s || class_name.foreign_key)
      end

      def association_primary_key(klass = nil)
        primary_key(klass || self.klass)
      end

      def active_record_primary_key
        custom_primary_key = options[:primary_key]
        @active_record_primary_key ||= if custom_primary_key
          if custom_primary_key.is_a?(Array)
            custom_primary_key.map { |pk| pk.to_s.freeze }.freeze
          else
            custom_primary_key.to_s.freeze
          end
        elsif active_record.has_query_constraints? || options[:query_constraints]
          active_record.query_constraints_list
        elsif active_record.composite_primary_key?
          # If active_record has composite primary key of shape [:<tenant_key>, :id], infer primary_key as :id
          primary_key = primary_key(active_record)
          primary_key.include?("id") ? "id" : primary_key.freeze
        else
          primary_key(active_record).freeze
        end
      end

      def join_primary_key(klass = nil)
        foreign_key
      end

      def join_primary_type
        type
      end

      def join_foreign_key
        active_record_primary_key
      end

      def check_validity!
        return if @validated

        check_validity_of_inverse!

        if !polymorphic? && (klass.composite_primary_key? || active_record.composite_primary_key?)
          if (has_one? || collection?) && Array(active_record_primary_key).length != Array(foreign_key).length
            raise CompositePrimaryKeyMismatchError.new(self)
          elsif belongs_to? && Array(association_primary_key).length != Array(foreign_key).length
            raise CompositePrimaryKeyMismatchError.new(self)
          end
        end

        @validated = true
      end

      def check_eager_loadable!
        return unless scope

        unless scope.arity == 0
          raise ArgumentError, <<-MSG.squish
            The association scope '#{name}' is instance dependent (the scope
            block takes an argument). Eager loading instance dependent scopes
            is not supported.
          MSG
        end
      end

      def join_id_for(owner) # :nodoc:
        Array(join_foreign_key).map { |key| owner._read_attribute(key) }
      end

      def through_reflection
        nil
      end

      def source_reflection
        self
      end

      # A chain of reflections from this one back to the owner. For more see the explanation in
      # ThroughReflection.
      def collect_join_chain
        [self]
      end

      # This is for clearing cache on the reflection. Useful for tests that need to compare
      # SQL queries on associations.
      def clear_association_scope_cache # :nodoc:
        klass.initialize_find_by_cache
      end

      def nested?
        false
      end

      def has_scope?
        scope
      end

      def has_inverse?
        inverse_name
      end

      def polymorphic_inverse_of(associated_class)
        if has_inverse?
          if inverse_relationship = associated_class._reflect_on_association(options[:inverse_of])
            inverse_relationship
          else
            raise InverseOfAssociationNotFoundError.new(self, associated_class)
          end
        end
      end

      # Returns the macro type.
      #
      # <tt>has_many :clients</tt> returns <tt>:has_many</tt>
      def macro; raise NotImplementedError; end

      # Returns whether or not this association reflection is for a collection
      # association. Returns +true+ if the +macro+ is either +has_many+ or
      # +has_and_belongs_to_many+, +false+ otherwise.
      def collection?
        false
      end

      # Returns whether or not the association should be validated as part of
      # the parent's validation.
      #
      # Unless you explicitly disable validation with
      # <tt>validate: false</tt>, validation will take place when:
      #
      # * you explicitly enable validation; <tt>validate: true</tt>
      # * you use autosave; <tt>autosave: true</tt>
      # * the association is a +has_many+ association
      def validate?
        !options[:validate].nil? ? options[:validate] : (options[:autosave] == true || collection?)
      end

      # Returns +true+ if +self+ is a +belongs_to+ reflection.
      def belongs_to?; false; end

      # Returns +true+ if +self+ is a +has_one+ reflection.
      def has_one?; false; end

      def association_class; raise NotImplementedError; end

      def polymorphic?
        options[:polymorphic]
      end

      def polymorphic_name
        active_record.polymorphic_name
      end

      def add_as_source(seed)
        seed
      end

      def add_as_polymorphic_through(reflection, seed)
        seed + [PolymorphicReflection.new(self, reflection)]
      end

      def add_as_through(seed)
        seed + [self]
      end

      def extensions
        Array(options[:extend])
      end

      def deprecated?
        @deprecated
      end

      private
        # Attempts to find the inverse association name automatically.
        # If it cannot find a suitable inverse association name, it returns
        # +nil+.
        def inverse_name
          unless defined?(@inverse_name)
            @inverse_name = options.fetch(:inverse_of) { automatic_inverse_of }
          end

          @inverse_name
        end

        # returns either +nil+ or the inverse association name that it finds.
        def automatic_inverse_of
          if can_find_inverse_of_automatically?(self)
            inverse_name = ActiveSupport::Inflector.underscore(options[:as] || active_record.name.demodulize).to_sym

            begin
              reflection = klass._reflect_on_association(inverse_name)
              if !reflection && active_record.automatically_invert_plural_associations
                plural_inverse_name = ActiveSupport::Inflector.pluralize(inverse_name)
                reflection = klass._reflect_on_association(plural_inverse_name)
              end
            rescue NameError => error
              raise unless error.name.to_s == class_name

              # Give up: we couldn't compute the klass type so we won't be able
              # to find any associations either.
              reflection = false
            end

            if valid_inverse_reflection?(reflection)
              reflection.name
            end
          end
        end

        # Checks if the inverse reflection that is returned from the
        # +automatic_inverse_of+ method is a valid reflection. We must
        # make sure that the reflection's active_record name matches up
        # with the current reflection's klass name.
        def valid_inverse_reflection?(reflection)
          reflection &&
            reflection != self &&
            foreign_key == reflection.foreign_key &&
            klass <= reflection.active_record &&
            can_find_inverse_of_automatically?(reflection, true)
        end

        # Checks to see if the reflection doesn't have any options that prevent
        # us from being able to guess the inverse automatically. First, the
        # <tt>inverse_of</tt> option cannot be set to false. Second, we must
        # have <tt>has_many</tt>, <tt>has_one</tt>, <tt>belongs_to</tt> associations.
        # Third, we must not have options such as <tt>:foreign_key</tt>
        # which prevent us from correctly guessing the inverse association.
        def can_find_inverse_of_automatically?(reflection, inverse_reflection = false)
          reflection.options[:inverse_of] != false &&
            !reflection.options[:through] &&
            !reflection.options[:foreign_key] &&
            scope_allows_automatic_inverse_of?(reflection, inverse_reflection)
        end

        # Scopes on the potential inverse reflection prevent automatic
        # <tt>inverse_of</tt>, since the scope could exclude the owner record
        # we would inverse from. Scopes on the reflection itself allow for
        # automatic <tt>inverse_of</tt> as long as
        # <tt>config.active_record.automatic_scope_inversing<tt> is set to
        # +true+ (the default for new applications).
        def scope_allows_automatic_inverse_of?(reflection, inverse_reflection)
          if inverse_reflection
            !reflection.scope
          else
            !reflection.scope || reflection.klass.automatic_scope_inversing
          end
        end

        def derive_class_name
          class_name = name.to_s
          class_name = class_name.singularize if collection?
          class_name.camelize
        end

        def derive_foreign_key(infer_from_inverse_of: true)
          if belongs_to?
            "#{name}_id"
          elsif options[:as]
            "#{options[:as]}_id"
          elsif options[:inverse_of] && infer_from_inverse_of
            inverse_of.foreign_key(infer_from_inverse_of: false)
          else
            active_record.model_name.to_s.foreign_key
          end
        end

        def derive_fk_query_constraints(foreign_key)
          primary_query_constraints = active_record.query_constraints_list
          owner_pk = active_record.primary_key

          if primary_query_constraints.size > 2
            raise ArgumentError, <<~MSG.squish
              The query constraints list on the `#{active_record}` model has more than 2
              attributes. Active Record is unable to derive the query constraints
              for the association. You need to explicitly define the query constraints
              for this association.
            MSG
          end

          if !primary_query_constraints.include?(owner_pk)
            raise ArgumentError, <<~MSG.squish
              The query constraints on the `#{active_record}` model does not include the primary
              key so Active Record is unable to derive the foreign key constraints for
              the association. You need to explicitly define the query constraints for this
              association.
            MSG
          end

          return foreign_key if primary_query_constraints.include?(foreign_key)

          first_key, last_key = primary_query_constraints

          if first_key == owner_pk
            [foreign_key, last_key.to_s]
          elsif last_key == owner_pk
            [first_key.to_s, foreign_key]
          else
            raise ArgumentError, <<~MSG.squish
              Active Record couldn't correctly interpret the query constraints
              for the `#{active_record}` model. The query constraints on `#{active_record}` are
              `#{primary_query_constraints}` and the foreign key is `#{foreign_key}`.
              You need to explicitly set the query constraints for this association.
            MSG
          end
        end

        def derive_join_table
          ModelSchema.derive_join_table_name active_record.table_name, klass.table_name
        end

      protected
        # Recursively sanitize the +parent_reflection+ (set by HABTM setup
        # to point at the owning HABTM reflection, which itself carries
        # scopes / extensions).
        def strip_unshareable_state!
          super
          parent = parent_reflection
          if parent
            self.parent_reflection = parent.shareable_clone
          end
        end
    end

    class HasManyReflection < AssociationReflection # :nodoc:
      def macro; :has_many; end

      def collection?; true; end

      def association_class
        if options[:through]
          Associations::HasManyThroughAssociation
        else
          Associations::HasManyAssociation
        end
      end
    end

    class HasOneReflection < AssociationReflection # :nodoc:
      def macro; :has_one; end

      def has_one?; true; end

      def association_class
        if options[:through]
          Associations::HasOneThroughAssociation
        else
          Associations::HasOneAssociation
        end
      end
    end

    class BelongsToReflection < AssociationReflection # :nodoc:
      def macro; :belongs_to; end

      def belongs_to?; true; end

      def association_class
        if polymorphic?
          Associations::BelongsToPolymorphicAssociation
        else
          Associations::BelongsToAssociation
        end
      end

      # klass option is necessary to support loading polymorphic associations
      def association_primary_key(klass = nil)
        if primary_key = options[:primary_key]
          @association_primary_key ||= if primary_key.is_a?(Array)
            primary_key.map { |pk| pk.to_s.freeze }.freeze
          else
            -primary_key.to_s
          end
        elsif (klass || self.klass).has_query_constraints? || options[:query_constraints]
          (klass || self.klass).composite_query_constraints_list
        elsif (klass || self.klass).composite_primary_key?
          # If klass has composite primary key of shape [:<tenant_key>, :id], infer primary_key as :id
          primary_key = (klass || self.klass).primary_key
          primary_key.include?("id") ? "id" : primary_key
        else
          primary_key(klass || self.klass)
        end
      end

      def join_primary_key(klass = nil)
        polymorphic? ? association_primary_key(klass) : association_primary_key
      end

      def join_foreign_key
        foreign_key
      end

      def join_foreign_type
        foreign_type
      end

      private
        def can_find_inverse_of_automatically?(*)
          !polymorphic? && super
        end
    end

    class HasAndBelongsToManyReflection < AssociationReflection # :nodoc:
      def macro; :has_and_belongs_to_many; end

      def collection?
        true
      end
    end

    # Holds all the metadata about a :through association as it was specified
    # in the Active Record class.
    class ThroughReflection < AbstractReflection # :nodoc:
      delegate :foreign_key, :foreign_type, :association_foreign_key, :join_id_for, :type,
               :active_record_primary_key, :join_foreign_key, to: :source_reflection

      def initialize(delegate_reflection)
        super()

        @validated = false
        @delegate_reflection = delegate_reflection
        @klass = delegate_reflection.options[:anonymous_class]
        @source_reflection_name = delegate_reflection.options[:source]

        ensure_option_not_given_as_class!(:source_type)
      end

      def through_reflection?
        true
      end

      def klass
        @klass ||= delegate_reflection._klass(class_name)
      end

      # Returns the source of the through reflection. It checks both a singularized
      # and pluralized form for <tt>:belongs_to</tt> or <tt>:has_many</tt>.
      #
      #   class Post < ActiveRecord::Base
      #     has_many :taggings
      #     has_many :tags, through: :taggings
      #   end
      #
      #   class Tagging < ActiveRecord::Base
      #     belongs_to :post
      #     belongs_to :tag
      #   end
      #
      #   tags_reflection = Post.reflect_on_association(:tags)
      #   tags_reflection.source_reflection
      #   # => <ActiveRecord::Reflection::BelongsToReflection: @name=:tag, @active_record=Tagging, @plural_name="tags">
      #
      def source_reflection
        return unless source_reflection_name

        through_reflection.klass._reflect_on_association(source_reflection_name)
      end

      # Returns the AssociationReflection object specified in the <tt>:through</tt> option
      # of a HasManyThrough or HasOneThrough association.
      #
      #   class Post < ActiveRecord::Base
      #     has_many :taggings
      #     has_many :tags, through: :taggings
      #   end
      #
      #   tags_reflection = Post.reflect_on_association(:tags)
      #   tags_reflection.through_reflection
      #   # => <ActiveRecord::Reflection::HasManyReflection: @name=:taggings, @active_record=Post, @plural_name="taggings">
      #
      def through_reflection
        active_record._reflect_on_association(options[:through])
      end

      # Returns an array of reflections which are involved in this association. Each item in the
      # array corresponds to a table which will be part of the query for this association.
      #
      # The chain is built by recursively calling #chain on the source reflection and the through
      # reflection. The base case for the recursion is a normal association, which just returns
      # [self] as its #chain.
      #
      #   class Post < ActiveRecord::Base
      #     has_many :taggings
      #     has_many :tags, through: :taggings
      #   end
      #
      #   tags_reflection = Post.reflect_on_association(:tags)
      #   tags_reflection.chain
      #   # => [<ActiveRecord::Reflection::ThroughReflection: @delegate_reflection=#<ActiveRecord::Reflection::HasManyReflection: @name=:tags...>,
      #         <ActiveRecord::Reflection::HasManyReflection: @name=:taggings, @options={}, @active_record=Post>]
      #
      def collect_join_chain
        collect_join_reflections [self]
      end

      # This is for clearing cache on the reflection. Useful for tests that need to compare
      # SQL queries on associations.
      def clear_association_scope_cache # :nodoc:
        delegate_reflection.clear_association_scope_cache
        source_reflection.clear_association_scope_cache
        through_reflection.clear_association_scope_cache
      end

      def scopes
        source_reflection.scopes + super
      end

      def join_scopes(table, predicate_builder = nil, klass = self.klass, record = nil) # :nodoc:
        source_reflection.join_scopes(table, predicate_builder, klass, record) + super
      end

      def has_scope?
        scope || options[:source_type] ||
          source_reflection.has_scope? ||
          through_reflection.has_scope?
      end

      # A through association is nested if there would be more than one join table
      def nested?
        source_reflection.through_reflection? || through_reflection.through_reflection?
      end

      # We want to use the klass from this reflection, rather than just delegate straight to
      # the source_reflection, because the source_reflection may be polymorphic. We still
      # need to respect the source_reflection's :primary_key option, though.
      def association_primary_key(klass = nil)
        # Get the "actual" source reflection if the immediate source reflection has a
        # source reflection itself
        if primary_key = actual_source_reflection.options[:primary_key]
          @association_primary_key ||= if primary_key.is_a?(Array)
            primary_key.map { |pk| pk.to_s.freeze }.freeze
          else
            -primary_key.to_s
          end
        else
          primary_key(klass || self.klass)
        end
      end

      def join_primary_key(klass = self.klass)
        source_reflection.join_primary_key(klass)
      end

      # Gets an array of possible <tt>:through</tt> source reflection names in both singular and plural form.
      #
      #   class Post < ActiveRecord::Base
      #     has_many :taggings
      #     has_many :tags, through: :taggings
      #   end
      #
      #   tags_reflection = Post.reflect_on_association(:tags)
      #   tags_reflection.source_reflection_names
      #   # => [:tag, :tags]
      #
      def source_reflection_names
        options[:source] ? [options[:source]] : [name.to_s.singularize, name].uniq
      end

      def source_reflection_name # :nodoc:
        @source_reflection_name ||= begin
          names = [name.to_s.singularize, name].collect(&:to_sym).uniq
          names = names.find_all { |n|
            through_reflection.klass._reflect_on_association(n)
          }

          if names.length > 1
            raise AmbiguousSourceReflectionForThroughAssociation.new(
              active_record.name,
              macro,
              name,
              options,
              source_reflection_names
            )
          end
          names.first
        end
      end

      def source_options
        source_reflection.options
      end

      def through_options
        through_reflection.options
      end

      def check_validity!
        return if @validated

        if through_reflection.nil?
          raise HasManyThroughAssociationNotFoundError.new(active_record, self)
        end

        if through_reflection.polymorphic?
          if has_one?
            raise HasOneAssociationPolymorphicThroughError.new(active_record.name, self)
          else
            raise HasManyThroughAssociationPolymorphicThroughError.new(active_record.name, self)
          end
        end

        if source_reflection.nil?
          raise HasManyThroughSourceAssociationNotFoundError.new(self)
        end

        if options[:source_type] && !source_reflection.polymorphic?
          raise HasManyThroughAssociationPointlessSourceTypeError.new(active_record.name, self, source_reflection)
        end

        if source_reflection.polymorphic? && options[:source_type].nil?
          raise HasManyThroughAssociationPolymorphicSourceError.new(active_record.name, self, source_reflection)
        end

        if has_one? && through_reflection.collection?
          raise HasOneThroughCantAssociateThroughCollection.new(active_record.name, self, through_reflection)
        end

        if parent_reflection.nil?
          reflections = active_record.normalized_reflections.keys

          if reflections.index(through_reflection.name) > reflections.index(name)
            raise HasManyThroughOrderError.new(active_record.name, self, through_reflection)
          end
        end

        check_validity_of_inverse!

        @validated = true
      end

      def constraints
        scope_chain = source_reflection.constraints
        scope_chain << scope if scope
        scope_chain
      end

      def add_as_source(seed)
        collect_join_reflections seed
      end

      def add_as_polymorphic_through(reflection, seed)
        collect_join_reflections(seed + [PolymorphicReflection.new(self, reflection)])
      end

      def add_as_through(seed)
        collect_join_reflections(seed + [self])
      end

      def deprecated_nested_reflections
        @deprecated_nested_reflections ||= collect_deprecated_nested_reflections
      end

      protected
        def actual_source_reflection # FIXME: this is a horrible name
          source_reflection.actual_source_reflection
        end

      private
        attr_reader :delegate_reflection

        def collect_join_reflections(seed)
          a = source_reflection.add_as_source seed
          if options[:source_type]
            through_reflection.add_as_polymorphic_through self, a
          else
            through_reflection.add_as_through a
          end
        end

        def inverse_name; delegate_reflection.send(:inverse_name); end

        def derive_class_name
          # get the class_name of the belongs_to association of the through reflection
          options[:source_type] || source_reflection.class_name
        end

        def collect_deprecated_nested_reflections
          result = []
          [through_reflection, source_reflection].each do |reflection|
            result << reflection if reflection.deprecated?
            # Both the through and the source reflections could be through
            # themselves. Nesting can go an arbitrary number of levels down.
            if reflection.through_reflection?
              result.concat(reflection.deprecated_nested_reflections)
            end
          end
          result
        end

        delegate_methods = AssociationReflection.public_instance_methods -
          public_instance_methods

        delegate(*delegate_methods, to: :delegate_reflection)

      protected
        # +ThroughReflection+ wraps a +@delegate_reflection+ that carries the
        # original macro's options (and therefore its own +@scope+ /
        # +options[:extend]+). Sanitize that delegate too so the deep-freeze
        # walk doesn't choke on it.
        def strip_unshareable_state!
          super
          if delegate_reflection
            instance_variable_set(:@delegate_reflection, delegate_reflection.shareable_clone)
          end
        end
    end

    class PolymorphicReflection < AbstractReflection # :nodoc:
      delegate :klass, :scope, :plural_name, :type, :join_primary_key, :join_foreign_key,
               :name, :scope_for, to: :@reflection

      def initialize(reflection, previous_reflection)
        super()
        @reflection = reflection
        @previous_reflection = previous_reflection
      end

      def join_scopes(table, predicate_builder = nil, klass = self.klass, record = nil) # :nodoc:
        scopes = super
        unless @previous_reflection.through_reflection?
          scopes += @previous_reflection.join_scopes(table, predicate_builder, klass, record)
        end
        scopes << build_scope(table, predicate_builder, klass).instance_exec(record, &source_type_scope)
      end

      def constraints
        @reflection.constraints + [source_type_scope]
      end

      private
        def source_type_scope
          type = @previous_reflection.foreign_type
          source_type = @previous_reflection.options[:source_type]
          lambda { |object| where(type => source_type) }
        end
    end

    class RuntimeReflection < AbstractReflection # :nodoc:
      delegate :scope, :type, :constraints, :join_foreign_key, to: :@reflection

      def initialize(reflection, association)
        super()
        @reflection = reflection
        @association = association
      end

      def klass
        @association.klass
      end

      def aliased_table
        klass.arel_table
      end

      def join_primary_key(klass = self.klass)
        @reflection.join_primary_key(klass)
      end

      def all_includes; yield; end
    end
  end
end
