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
        return super if Ractor.main? || @none
        # Reduce conditional exists? (e.g. has_secure_token's uniqueness check)
        # to the dispatched no-argument form.
        return where(conditions).exists? if conditions != :none

        shareable_arel = Ractor.make_shareable(limit(1).arel, copy: true)
        model_name = model.name
        Ractor::Dispatch.main.run do
          klass = Object.const_get(model_name)
          klass.with_connection { |c| !c.select_all(shareable_arel).empty? }
        end
      end

      # Building an association scope needs an AliasTracker, whose factory opens
      # a connection just to read table_alias_length (a static per-adapter
      # value) when there are no joins. Use the captured value in a non-main
      # Ractor so scopes can be built without a connection.
      def alias_tracker(joins = [], aliases = nil)
        return super if Ractor.main? || !joins.empty?

        length = ActiveRecord::RactorPatches.table_alias_length
        return super if length.nil?

        aliases ||= Hash.new(0)
        aliases[table.name] = 1
        ActiveRecord::Associations::AliasTracker.new(length, aliases)
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
    # Warm lazily-computed reflection state that consults the connection/schema
    # (class_name/inverse_of walk the associated class and call #inspect ->
    # table_exists?). This must run for ALL reflections of ALL models before any
    # reflection is frozen, because a reflection's inverse lookup reaches into
    # another model's (possibly not-yet-warmed) reflections. Once warmed, a
    # non-main Ractor never triggers the connection, and freezing won't try to
    # memoize onto a frozen reflection.
    def self.warm_reflection!(reflection)
      %i[class_name inverse_of klass foreign_key active_record_primary_key
         join_primary_key join_foreign_key type].each do |m|
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
    end

    def self.freeze_reflection!(reflection)
      Ractor.make_shareable(reflection)
    rescue Ractor::Error, Ractor::IsolationError, StandardError
    end

    class << self
      attr_accessor :table_alias_length
    end

    # A non-main Ractor can't own a connection, so it can't execute the INSERT
    # for a new record. Dispatch the write to the main Ractor: ship a shareable
    # {column => value_for_database} payload, build and run the INSERT there,
    # and copy the returning values (e.g. the new id) back onto the record.
    module PersistenceWriteDispatch
      def _create_record(attribute_names = self.attribute_names)
        return super if Ractor.main?

        attribute_names = attributes_for_create(attribute_names)
        values = attributes_with_values(attribute_names)
        payload = {}
        values.each { |name, attr| payload[name] = attr.value_for_database }
        Ractor.make_shareable(payload)
        model_name = self.class.name

        columns, returning_values = Ractor::Dispatch.main.run do
          klass = Object.const_get(model_name)
          klass.with_connection do |connection|
            returning = klass._returning_columns_for_insert(connection)
            im = Arel::InsertManager.new(klass.arel_table)
            if payload.empty?
              im.insert(connection.empty_insert_statement_value(klass.primary_key))
            else
              im.insert(payload.transform_keys { |name| klass.arel_table[name] })
            end
            rv = connection.insert(im, "#{klass} Create", klass.primary_key || false, nil, returning: returning)
            Ractor.make_shareable([returning, rv])
          end
        end

        if returning_values
          columns.zip(returning_values).each do |column, value|
            _write_attribute(column, type_for_attribute(column).deserialize(value)) if !_read_attribute(column)
          end
        end

        @new_record = false
        @previously_new_record = true

        yield(self) if block_given?

        id
      end
    end

    # current_time_from_proper_timezone only opens a connection to read the
    # (global) default timezone; read it directly in a non-main Ractor.
    module TimestampDispatch
      def current_time_from_proper_timezone
        return super if Ractor.main?
        ActiveRecord.default_timezone == :utc ? Time.now.utc : Time.now
      end
    end

    # A non-main Ractor has no connection to open a real DB transaction. Run the
    # body without one; the dispatched INSERT/UPDATE is itself atomic.
    # EXPERIMENT: transactional (after_commit/after_rollback) callbacks and
    # multi-statement rollback safety are not supported here.
    module TransactionDispatch
      def with_transaction_returning_status
        return super if Ractor.main?

        status = yield
        raise ActiveRecord::Rollback unless status
        status
      rescue ActiveRecord::Rollback
        nil
      end
    end

    def self.warm_and_share!(klass)
      # Warm lazily-memoized relation state.
      klass.arel_table if klass.respond_to?(:arel_table)
      klass.predicate_builder if klass.respond_to?(:predicate_builder)

      if klass.respond_to?(:reflections)
        klass._reflections.each_value { |r| freeze_reflection!(r) }
      end
      # Model callback chains are made shareable centrally by
      # ActiveSupport::Callbacks.make_shareable.

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
  ActiveRecord::Persistence.prepend(ActiveRecord::RactorPatches::PersistenceWriteDispatch)
  ActiveRecord::Transactions.prepend(ActiveRecord::RactorPatches::TransactionDispatch)
  ActiveRecord::Timestamp::ClassMethods.prepend(ActiveRecord::RactorPatches::TimestampDispatch)

  # Delegation.uncacheable_methods memoizes a class ivar the first time a
  # relation delegates a method; warm it on the main Ractor.
  ActiveRecord::Delegation.uncacheable_methods if defined?(ActiveRecord::Delegation)

  # Capture the (static, per-adapter) table alias length so association scopes
  # can build an AliasTracker without a connection in a non-main Ractor.
  begin
    ActiveRecord::RactorPatches.table_alias_length =
      ActiveRecord::Base.with_connection { |c| c.table_alias_length }
  rescue StandardError
  end

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
       columns_hash columns column_names attribute_types arel_table predicate_builder
       define_attribute_methods all_timestamp_attributes_in_model
       timestamp_attributes_for_create_in_model timestamp_attributes_for_update_in_model
       _returning_columns_for_insert content_columns].each { |m| warm.call(klass, m) }
    # symbol_column_to_string(sym) memoizes @symbol_column_to_string_name_hash;
    # warm it with a throwaway argument.
    begin
      klass.symbol_column_to_string(:id) if klass.respond_to?(:symbol_column_to_string) && klass.table_exists?
    rescue StandardError
    end

    # Exercise the finder path to warm remaining lazily-memoized class state
    # (order columns, ...). Runs on the main Ractor where the connection exists.
    begin
      klass.first if klass.table_exists?
    rescue StandardError
    end
  end

  # Warm every reflection of every model before any are frozen (inverse lookups
  # cross model boundaries).
  (ActiveRecord::Base.descendants + [ActiveRecord::Base]).uniq.each do |klass|
    next unless klass.respond_to?(:_reflections)
    klass._reflections.each_value { |r| ActiveRecord::RactorPatches.warm_reflection!(r) }
  rescue StandardError
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
