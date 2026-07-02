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
    # Option 1: a Ractor connection proxy. A non-main Ractor can't own a DB
    # connection, so instead of dispatching individual query methods we hand the
    # request path a proxy connection whose every method call is executed on the
    # main Ractor (which owns the real connection) and whose result is returned
    # Ractor-shareable. This is transparent to the application: with_connection
    # yields the proxy, and select/insert/update/quote/... all forward to main.
    module ConnectionProxy
      def initialize(model_name)
        @model_name = model_name || "ActiveRecord::Base"
      end

      # Block-taking methods run their block in *this* Ractor (the block calls
      # back into the proxy for individual statements).
      def with_connection(*, **); yield self; end
      def unprepared_statement; yield; end
      def lease; end
      def expire; end
      def connection; self; end
      # schema_cache holds a Monitor (unshareable); return a proxy that forwards
      # its method calls to the main Ractor instead.
      def schema_cache; SchemaCacheProxyObject.for(@model_name); end

      # EXPERIMENT: a non-main Ractor has no real transaction; run the body
      # directly. Each forwarded statement is auto-committed on the main Ractor.
      def transaction(*, **)
        block_given? ? yield : nil
      end

      def method_missing(name, *args, **kwargs, &block)
        if block
          raise ArgumentError, "ConnectionProxy can't forward ##{name} with a block across Ractors"
        end
        model_name = @model_name
        # Some connection methods accept an ActiveRecord::Relation (which the
        # real connection converts via arel_from_relation). A Relation isn't
        # cleanly shareable and re-triggers query building when shipped, so
        # convert it to its Arel here (built in this Ractor) before dispatching.
        args = args.map { |a| a.is_a?(ActiveRecord::Relation) ? a.arel : a }
        shareable_args = Ractor.make_shareable(args, copy: true)
        shareable_kwargs = Ractor.make_shareable(kwargs, copy: true)
        Ractor::Dispatch.main.run do
          Object.const_get(model_name).with_connection do |conn|
            Ractor.make_shareable(conn.public_send(name, *shareable_args, **shareable_kwargs))
          end
        end
      end

      def respond_to_missing?(*)
        true
      end
    end

    # Minimal proxy for connection_pool (used e.g. by AliasTracker and
    # connection_db_config); forwards to the main Ractor's pool.
    module ConnectionPoolProxy
      def initialize(model_name)
        @model_name = model_name || "ActiveRecord::Base"
      end

      def with_connection(*, **); yield ConnectionProxyObject.for(@model_name); end
      def lease_connection; ConnectionProxyObject.for(@model_name); end
      def db_config; ActiveRecord::RactorPatches.main_db_config; end
      def schema_cache; ActiveRecord::RactorPatches.main_schema_cache; end

      def method_missing(name, *args, **kwargs, &block)
        raise ArgumentError, "ConnectionPoolProxy can't forward ##{name} with a block" if block
        model_name = @model_name
        shareable_args = Ractor.make_shareable(args, copy: true)
        shareable_kwargs = Ractor.make_shareable(kwargs, copy: true)
        Ractor::Dispatch.main.run do
          Object.const_get(model_name).connection_pool.public_send(name, *shareable_args, **shareable_kwargs).then { |r| Ractor.make_shareable(r) }
        end
      end

      def respond_to_missing?(*)
        true
      end
    end

    # In a non-main Ractor, hand out the proxy connection/pool instead of
    # touching the (unshareable) connection handler.
    module ConnectionHandlingProxy
      def with_connection(prevent_permanent_checkout: false, &block)
        return super if Ractor.main?
        block.call(ConnectionProxyObject.for(name))
      end

      def lease_connection
        return super if Ractor.main?
        ConnectionProxyObject.for(name)
      end

      def connection
        return super if Ractor.main?
        ConnectionProxyObject.for(name)
      end

      def connection_pool
        return super if Ractor.main?
        ConnectionPoolProxyObject.for(name)
      end
    end

    # Forwards schema_cache queries (columns, primary_keys, ...) to the main
    # Ractor's connection.
    module SchemaCacheProxy
      def initialize(model_name); @model_name = model_name || "ActiveRecord::Base"; end

      def method_missing(name, *args, **kwargs, &block)
        raise ArgumentError, "SchemaCacheProxy can't forward ##{name} with a block" if block
        model_name = @model_name
        shareable_args = Ractor.make_shareable(args, copy: true)
        shareable_kwargs = Ractor.make_shareable(kwargs, copy: true)
        Ractor::Dispatch.main.run do
          Object.const_get(model_name).with_connection do |conn|
            Ractor.make_shareable(conn.schema_cache.public_send(name, *shareable_args, **shareable_kwargs))
          end
        end
      end

      def respond_to_missing?(*)
        true
      end
    end

    # Small object classes that mix in the proxy behavior (BasicObject-like:
    # method_missing forwards everything).
    class ConnectionProxyObject
      include ConnectionProxy
      def self.for(model_name); new(model_name); end
    end

    class SchemaCacheProxyObject
      include SchemaCacheProxy
      def self.for(model_name); new(model_name); end
    end

    class ConnectionPoolProxyObject
      include ConnectionPoolProxy
      def self.for(model_name); new(model_name); end
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
      attr_accessor :table_alias_length, :main_db_config, :main_schema_cache
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
  ActiveRecord::Base.singleton_class.prepend(ActiveRecord::RactorPatches::ConnectionHandlingProxy)
  ActiveRecord::Transactions.prepend(ActiveRecord::RactorPatches::TransactionDispatch)
  ActiveRecord::Timestamp::ClassMethods.prepend(ActiveRecord::RactorPatches::TimestampDispatch)

  # Capture shareable connection metadata served by the pool proxy.
  begin
    ActiveRecord::RactorPatches.main_db_config = ActiveRecord::Base.connection_pool.db_config
    ActiveRecord::RactorPatches.main_schema_cache = ActiveRecord::Base.connection_pool.schema_cache
  rescue StandardError
  end

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
    # These memoize class ivars but take a connection argument, so the no-arg
    # warm above skips them; warm them explicitly on the main Ractor.
    begin
      if klass.respond_to?(:symbol_column_to_string) && klass.table_exists?
        klass.symbol_column_to_string(:id)
        klass.with_connection { |c| klass._returning_columns_for_insert(c) }
      end
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
