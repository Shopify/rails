# frozen_string_literal: true

# Active Record Ractor patches, applied by Rails::Application#ractorize!.
#
# Building a relation from a non-main Ractor reads model class-level state that
# is lazily memoized into class ivars (@arel_table, @predicate_builder, ...).
# Warm and share it so a non-main Ractor can read it.

require "active_support/ractors"
require "ractor/dispatch"

module ActiveRecord
  module RactorPatches # :nodoc:
    # Non-main Ractors can't own a DB connection (the pool isn't shareable), so
    # dispatch read queries to the main Ractor, which owns the connection, and
    # return a shareable ActiveRecord::Result. Limited to simple, synchronous
    # select queries (no async, eager-load, or contradictions), which the main
    # relation-loading path uses.
    module RelationQueryDispatch
      def exec_main_query(async: false)
        return super if Ractor.main?
        return super if @none || async || eager_loading? || where_clause.contradiction?

        shareable_arel = Ractor.make_shareable(arel, copy: true)
        model_name = model.name

        Ractor::Dispatch.main.run do
          klass = Object.const_get(model_name)
          klass.with_connection do |c|
            Ractor.make_shareable(klass._query_by_sql(c, shareable_arel))
          end
        end
      end
    end
    # Association reflections hold a scope Proc (invoked via instance_exec, so
    # self-detaching is safe) and Concurrent::Map caches. Make them shareable so
    # the whole _reflections hash can be read from a non-main Ractor.
    def self.make_reflection_shareable!(reflection)
      scope = reflection.instance_variable_get(:@scope) if reflection.instance_variable_defined?(:@scope)
      if scope.is_a?(Proc) && !Ractor.shareable?(scope)
        replacement =
          begin
            ActiveSupport::Ractors.shareable_proc(&scope)
          rescue Ractor::IsolationError
            # Some association scopes (e.g. ActiveStorage attachments) close over
            # further unshareable procs and can't be detached. Stub them so the
            # reflection is shareable; a non-main Ractor that actually invokes
            # this scope will raise (EXPERIMENT: not covered).
            Ractor.shareable_proc { raise "association scope is not Ractor-safe (experiment)" }
          end
        reflection.instance_variable_set(:@scope, replacement)
      end

      reflection.instance_variables.each do |ivar|
        value = reflection.instance_variable_get(ivar)
        # Drop mutable per-reflection caches (Concurrent::Map); they're rebuilt
        # lazily and aren't needed for the dispatched read path.
        if value.class.name == "Concurrent::Map"
          reflection.instance_variable_set(ivar, nil)
        end
      end

      begin
        Ractor.make_shareable(reflection)
      rescue Ractor::Error, Ractor::IsolationError, StandardError
      end
    end

    def self.warm_and_share!(klass)
      # Warm lazily-memoized relation state.
      klass.arel_table if klass.respond_to?(:arel_table)
      klass.predicate_builder if klass.respond_to?(:predicate_builder)

      if klass.respond_to?(:reflections)
        klass._reflections.each_value { |r| make_reflection_shareable!(r) }
      end

      # Make model class-level state (class_attribute values in @__class_attr_*,
      # memoized arel/predicate state, ...) shareable so a non-main Ractor can
      # read it while building a relation. Best-effort: values that can't be
      # frozen (e.g. procs, connection-bound objects) are left as-is.
      klass.instance_variables.each do |ivar|
        value = klass.instance_variable_get(ivar)
        next if Ractor.shareable?(value)
        begin
          klass.instance_variable_set(ivar, Ractor.make_shareable(value))
        rescue StandardError, Ractor::Error, Ractor::IsolationError
          # Value can't be frozen (e.g. Concurrent::Map, connection-bound); skip.
        end
      end
    end
  end
end

ActiveSupport::Ractors.before_freeze do
  ActiveRecord::Relation.prepend(ActiveRecord::RactorPatches::RelationQueryDispatch)
end

# adapter_class (a shareable Class) is reached via the unshareable connection
# handler; serve a captured value to non-main Ractors so query building (e.g.
# ORDER BY quoting) works without touching the connection.
ActiveSupport::Ractors.capture_class_reader(ActiveRecord::Base, :adapter_class)

ActiveSupport::Ractors.on_freeze do
  # Effectively-immutable relation constants read on the query-building path.
  Ractor.make_shareable(ActiveRecord::Relation::WhereClause::EMPTY) if defined?(ActiveRecord::Relation::WhereClause::EMPTY)

  models = ActiveRecord::Base.descendants.select { |k| k.respond_to?(:abstract_class?) }
  (models + [ActiveRecord::Base]).uniq.each do |klass|
    ActiveRecord::RactorPatches.warm_and_share!(klass)
  end
end
