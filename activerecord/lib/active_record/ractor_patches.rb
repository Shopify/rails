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

      # exists? (also backs empty?/none?/any?) runs a SELECT via the connection;
      # dispatch the no-argument case to the main Ractor.
      def exists?(conditions = :none)
        return super if Ractor.main? || conditions != :none || @none

        shareable_arel = Ractor.make_shareable(limit(1).arel, copy: true)
        model_name = model.name
        Ractor::Dispatch.main.run do
          klass = Object.const_get(model_name)
          klass.with_connection { |c| !c.select_all(shareable_arel).empty? }
        end
      end

      # to_sql (used e.g. for collection cache keys) compiles the arel via the
      # connection; dispatch that compilation to the main Ractor.
      def to_sql
        return super if Ractor.main? || @to_sql || eager_loading?

        shareable_arel = Ractor.make_shareable(arel, copy: true)
        model_name = model.name
        @to_sql = Ractor::Dispatch.main.run do
          klass = Object.const_get(model_name)
          klass.with_connection do |c|
            Ractor.make_shareable(c.unprepared_statement { c.to_sql(shareable_arel) })
          end
        end
      end
    end
    # Association reflections hold a scope Proc (invoked via instance_exec, so
    # self-detaching is safe) and Concurrent::Map caches. Make them shareable so
    # the whole _reflections hash can be read from a non-main Ractor.
    def self.make_reflection_shareable!(reflection)
      # Warm lazily-computed reflection state that consults the connection/schema
      # (inverse_of walks the associated class and calls #inspect -> table_exists?).
      # Doing it here on the main Ractor memoizes it before the reflection is
      # frozen, so a non-main Ractor never triggers the connection.
      %i[inverse_of klass foreign_key active_record_primary_key join_primary_key
         join_foreign_key type].each do |m|
        reflection.public_send(m) if reflection.respond_to?(m)
      rescue StandardError
      end
      # check_validity! memoizes @validated; warm it so the per-association-build
      # validity check (which calls Class#inspect -> table_exists?) is skipped in
      # a non-main Ractor.
      begin
        reflection.check_validity! if reflection.respond_to?(:check_validity!)
      rescue StandardError
      end

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

  # Delegation.uncacheable_methods memoizes a class ivar the first time a
  # relation delegates a method; warm it on the main Ractor.
  ActiveRecord::Delegation.uncacheable_methods if defined?(ActiveRecord::Delegation)

  # Warm model schema/relation state BEFORE anything is frozen (load_schema!
  # loads columns from the DB and memoizes class state; it must not run for the
  # first time inside a non-main Ractor).
  warm = ->(receiver, name) do
    receiver.send(name) if receiver.respond_to?(name, true)
  rescue StandardError
  end

  ActiveRecord::Base.descendants.each do |klass|
    next if klass.respond_to?(:abstract_class?) && klass.abstract_class?
    %i[load_schema finder_needs_type_condition? primary_key query_constraints_list
       columns_hash attribute_types arel_table predicate_builder].each { |m| warm.call(klass, m) }
    # Exercise the finder path to warm remaining lazily-memoized class state
    # (order columns, ...). Runs on the main Ractor where the connection exists.
    begin
      klass.first if klass.table_exists?
    rescue StandardError
    end
  end
end

# adapter_class (a shareable Class) is reached via the unshareable connection
# handler; serve a captured value to non-main Ractors so query building (e.g.
# ORDER BY quoting) works without touching the connection.
ActiveSupport::Ractors.capture_class_reader(ActiveRecord::Base, :adapter_class)

ActiveSupport::Ractors.on_freeze do
  # Effectively-immutable relation constants read on the query-building path.
  Ractor.make_shareable(ActiveRecord::Relation::WhereClause::EMPTY) if defined?(ActiveRecord::Relation::WhereClause::EMPTY)

  # AssociationScope::INSTANCE holds a self-contained identity lambda; freeze it
  # so association scopes can be built from a non-main Ractor.
  if defined?(ActiveRecord::Associations::AssociationScope::INSTANCE)
    Ractor.make_shareable(ActiveRecord::Associations::AssociationScope::INSTANCE)
  end

  models = ActiveRecord::Base.descendants.select { |k| k.respond_to?(:abstract_class?) }
  (models + [ActiveRecord::Base]).uniq.each do |klass|
    ActiveRecord::RactorPatches.warm_and_share!(klass)
  end
end
