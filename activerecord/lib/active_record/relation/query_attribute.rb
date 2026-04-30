# frozen_string_literal: true

require "active_model/attribute"

module ActiveRecord
  class Relation
    class QueryAttribute < ActiveModel::Attribute # :nodoc:
      def initialize(...)
        super

        # The query attribute value may be mutated before we actually "compile" the query.
        # To avoid that if the type uses a serializer we eagerly compute the value for database
        if value_before_type_cast.is_a?(StatementCache::Substitute)
          # we don't need to serialize StatementCache::Substitute
        elsif @type.serialized?
          value_for_database
        elsif @type.mutable? # If the type is simply mutable, we deep_dup it.
          unless @value_before_type_cast.frozen?
            @value_before_type_cast = @value_before_type_cast.deep_dup
          end
          # After the deep_dup the bind owns a private snapshot of
          # +@value_before_type_cast+; external code can no longer mutate the
          # value behind our back. Pre-resolving +@value_for_database+ now is
          # safe and prevents a +FrozenError+ when the bind crosses the
          # +RactorConnectionProxy+ / +RactorQueryDispatch+ boundary
          # (+Ractor.make_shareable(binds, copy: true)+ produces a deep-frozen
          # copy; the main-side SQL generator then calls
          # +bind.value_for_database+, and the lazy
          # +@value_for_database = _value_for_database+ would FrozenError on the
          # copy). Mirrors the existing pre-resolution in the +serialized?+ and
          # final +else+ branches.
          value_for_database
        else
          # Non-mutable, non-serialized values are stable for the lifetime of
          # the QueryAttribute. Pre-resolve +@value_for_database+ at
          # construction so the lazy +value_for_database+ memoization never
          # fires from a non-main Ractor (the ivar write would FrozenError on
          # a deep-frozen attribute crossing the +RactorQueryDispatch+
          # boundary, and +Ractor::IsolationError+ on a class-shared
          # attribute read from non-main).
          value_for_database
        end

        # Pre-resolve +@_unboundable+ for the same boundary-safety reason as
        # +@value_for_database+. The Arel SQL visitor calls +bind.unboundable?+
        # on the main side after +Ractor.make_shareable(binds, copy: true)+ has
        # deep-frozen the bind graph; the lazy +@_unboundable = ...+ ivar write
        # in +unboundable?+ would otherwise +FrozenError+ on the copy. Eagerly
        # populate the ivar at construction so the main-side visitor only ever
        # reads it. Skipped for +StatementCache::Substitute+ binds, whose value
        # is not yet known and whose +unboundable?+ is never consulted.
        unless value_before_type_cast.is_a?(StatementCache::Substitute)
          unboundable?
        end
      end

      def type_cast(value)
        value
      end

      def value_for_database
        @value_for_database = _value_for_database unless defined?(@value_for_database)
        @value_for_database
      end

      def with_cast_value(value)
        QueryAttribute.new(name, value, type)
      end

      def nil?
        unless value_before_type_cast.is_a?(StatementCache::Substitute)
          value_before_type_cast.nil? ||
            (type.respond_to?(:subtype) || type.respond_to?(:normalizer)) && serializable? && value_for_database.nil?
        end
      end

      def infinite?
        infinity?(value_before_type_cast) || serializable? && infinity?(value_for_database)
      end

      def unboundable?
        unless defined?(@_unboundable)
          serializable? { |value| @_unboundable = value <=> 0 } && @_unboundable = nil
        end
        @_unboundable
      end

      def ==(other)
        super && value_for_database == other.value_for_database
      end
      alias eql? ==

      def hash
        [self.class, name, value_for_database, type].hash
      end

      private
        def infinity?(value)
          value.respond_to?(:infinite?) && value.infinite?
        end
    end
  end
end
