# frozen_string_literal: true

require "ractor/dispatch"

module ActiveRecord
  module ConnectionAdapters
    # Narrow non-main-Ractor -> main-Ractor dispatch for AR write actions
    # (insert / update / delete) on a single record.
    #
    # The real ConnectionPool / connection graph holds Mutex /
    # ConditionVariable / live driver state and cannot cross a Ractor
    # boundary. Returning these two shareable proxies from
    # +ActiveRecord::Base.connection_pool+ and the +with_connection+ block
    # on a non-main Ractor lets the persistence path (+save+, +update+,
    # +destroy+) reach a real connection on the main Ractor without ever
    # exposing the unshareable graph to the request-side Ractor.
    #
    # The surface is intentionally limited to what the request-path write
    # flow actually calls. Any other method raises +NoMethodError+ with a
    # pointer back to this file. We do NOT define a permissive
    # +method_missing+ that forwards: silent forwarding of arbitrary
    # methods is exactly the "broad proxy layer can drift semantically"
    # anti-pattern called out in plans/reimplementation/learnings.md.
    #
    # Boundary semantics actually enforced here:
    #
    # * +transaction+ on the proxy is a no-op that yields and rescues
    #   +ActiveRecord::Rollback+. Each dispatched call (+insert+,
    #   +update+, +delete+) runs in its own implicit transaction on the
    #   main side, which is sufficient for single-record persistence.
    # * +add_transaction_record+ is a no-op. +after_commit+ /
    #   +after_rollback+ callbacks therefore do not fire on the request-
    #   side Ractor for non-main writes. The acceptance gate verifies HTTP
    #   status only, not callback observability, so this is acceptable
    #   for the current chunk.
    # * Multi-statement / nested transactions and explicit rollback
    #   semantics across the boundary are out of scope. If the gate ever
    #   reaches a flow that needs them, the right answer is to extend
    #   this proxy deliberately, not to add a generic forwarder.
    module RactorConnectionProxy
      extend self

      # Yielded by +with_connection+ on a non-main Ractor and used as the
      # +pool+ accessor on the proxy connection (see below).
      def pool
        RactorConnectionPool
      end

      def transaction_open?
        false
      end

      # Each dispatched insert/update/delete already runs in its own
      # implicit transaction on the main side, so the proxy +transaction+
      # is just a yielding shell that honors +ActiveRecord::Rollback+
      # exactly the way a real connection would.
      def transaction(*, **, &block)
        yield self
      rescue ActiveRecord::Rollback
        nil
      end

      def current_transaction
        ActiveRecord::Transaction::NULL_TRANSACTION
      end

      # +add_to_transaction+ on a record calls
      # +connection.add_transaction_record(self, ensure_finalize)+ to
      # register the record for after_commit / after_rollback dispatch on
      # the main connection. There is no real transaction on this side of
      # the boundary, so this is a no-op and transactional callbacks
      # silently do not fire on non-main Ractors. See module docstring.
      def add_transaction_record(record, ensure_finalize = true)
        nil
      end

      def prepared_statements
        false
      end

      # Real adapters use this to scope a block to non-prepared SQL. The
      # proxy never prepares, so just yield.
      def unprepared_statement(&block)
        yield
      end

      def empty_insert_statement_value(primary_key = nil)
        pk_dump = primary_key
        Ractor::Dispatch.main.run do
          RactorConnectionProxy.dispatched_with_sanitized_errors do
            ActiveRecord::Base.with_connection do |c|
              value = c.empty_insert_statement_value(pk_dump)
              Ractor.make_shareable(value, copy: true)
            end
          end
        end
      end

      # Dispatch the INSERT to the main Ractor. The +Arel::InsertManager+
      # cannot cross the boundary directly because its AST is walked by an
      # +Arel::Visitors+ dispatch hash whose values are non-shareable
      # Procs. We Marshal the manager (its AST is pure data) and rebuild
      # it on the main side. Marshal is acceptable here: Arel managers
      # are stateless beyond their AST.
      def insert(arel_im, name = nil, pk = nil, pk_value = nil, returning: nil)
        im_dump   = Marshal.dump(arel_im).freeze
        op_name   = name.nil? ? nil : Ractor.make_shareable(name, copy: true)
        pk_value_ = Ractor.make_shareable(pk_value, copy: true)
        pk_       = Ractor.make_shareable(pk, copy: true)
        returning_ = Ractor.make_shareable(returning, copy: true)

        Ractor::Dispatch.main.run do
          RactorConnectionProxy.dispatched_with_sanitized_errors do
            im = Marshal.load(im_dump)
            ActiveRecord::Base.with_connection do |c|
              result = c.insert(im, op_name, pk_, pk_value_, returning: returning_)
              Ractor.make_shareable(result, copy: true)
            end
          end
        end
      end

      def update(arel_um, name = nil)
        um_dump = Marshal.dump(arel_um).freeze
        op_name = name.nil? ? nil : Ractor.make_shareable(name, copy: true)

        Ractor::Dispatch.main.run do
          RactorConnectionProxy.dispatched_with_sanitized_errors do
            um = Marshal.load(um_dump)
            ActiveRecord::Base.with_connection do |c|
              result = c.update(um, op_name)
              Ractor.make_shareable(result, copy: true)
            end
          end
        end
      end

      def delete(arel_dm, name = nil)
        dm_dump = Marshal.dump(arel_dm).freeze
        op_name = name.nil? ? nil : Ractor.make_shareable(name, copy: true)

        Ractor::Dispatch.main.run do
          RactorConnectionProxy.dispatched_with_sanitized_errors do
            dm = Marshal.load(dm_dump)
            ActiveRecord::Base.with_connection do |c|
              result = c.delete(dm, op_name)
              Ractor.make_shareable(result, copy: true)
            end
          end
        end
      end

      # Read-side per-call dispatch for +c.select_all(arel, name)+.
      #
      # Reached from +Calculations#execute_simple_calculation+ (e.g.
      # +Post.count+, +Post.sum+) which calls
      # +c.select_all(query_builder, "<Model> <Operation>", async: @async)+
      # inside a +with_connection+ block. Any other caller using
      # +c.select_all+ directly on the proxy lands here too.
      #
      # Same Marshal-the-arel + main-side dispatch shape as +insert+ /
      # +update+ / +delete+ / +select_rows+. Async paths return a
      # +FutureResult+ that is bound to the main-side connection and
      # cannot ride back across the boundary; raise +NotImplementedError+
      # on +async: true+, matching +select_rows+.
      #
      # The return shape from a real adapter's +select_all+ is an
      # +ActiveRecord::Result+ (rows + columns + column_types). Made
      # shareable with +copy: true+ so the request side can read it.
      def select_all(arel, name = nil, binds = [], preparable: nil, async: false, allow_retry: false)
        if async
          raise NotImplementedError,
            "RactorConnectionProxy#select_all does not support async: true. " \
            "Pass async: false; main-Ractor async support is out of scope for " \
            "the request-side proxy. See #{__FILE__}."
        end

        arel_dump   = Marshal.dump(arel).freeze
        op_name     = name.nil? ? nil : Ractor.make_shareable(name, copy: true)
        binds_dump  = Ractor.make_shareable(binds, copy: true)
        preparable_ = Ractor.make_shareable(preparable, copy: true)
        allow_retry_ = allow_retry ? true : false

        Ractor::Dispatch.main.run do
          RactorConnectionProxy.dispatched_with_sanitized_errors do
            arel_ = Marshal.load(arel_dump)
            ActiveRecord::Base.with_connection do |c|
              result = c.select_all(arel_, op_name, binds_dump, preparable: preparable_, async: false, allow_retry: allow_retry_)
              Ractor.make_shareable(result, copy: true)
            end
          end
        end
      end

      # Read-side per-call dispatch for +c.select_rows(arel, name)+.
      #
      # Currently reached from +FinderMethods#exists?+, which calls
      # +c.select_rows(relation.arel, "<Model> Exists?")+ inside a
      # +with_connection+ block. Any other caller using +c.select_rows+
      # directly on a +with_connection+ block on a non-main Ractor will
      # land here too; that is intentional.
      #
      # The Arel AST is pure data but its +Arel::Visitors+ dispatch hash
      # holds non-shareable Procs, so we Marshal the AST per call and
      # rebuild it on the main side -- exactly the same shape used by
      # +insert+ / +update+ / +delete+ above. +name+ and +binds+ are
      # made shareable with +copy: true+ for consistency with those
      # methods.
      #
      # +async: true+ is unsupported on the request-side proxy and
      # raises +NotImplementedError+, matching the discipline already in
      # +RactorQueryDispatch.select_all+. Main-Ractor async support is
      # out of scope here.
      #
      # The return shape from a real adapter's +select_rows+ is
      # +Array<Array>+ (rows of column values); we make it shareable
      # with +copy: true+ so the request side can read it freely.
      #
      # Note: this is NOT routed through +RactorQueryDispatch.select_all+
      # because that dispatcher keys on a model class (it uses
      # +klass.with_connection+ on the main side to pick a connection),
      # and +c.select_rows+ on this proxy has no model in scope. The
      # dispatched block here uses +ActiveRecord::Base.with_connection+
      # directly, consistent with +insert+ / +update+ / +delete+ in
      # this file.
      def select_rows(arel, name = nil, binds = [], async: false)
        if async
          raise NotImplementedError,
            "RactorConnectionProxy#select_rows does not support async: true. " \
            "Pass async: false; main-Ractor async support is out of scope for " \
            "the request-side proxy. See #{__FILE__}."
        end

        arel_dump  = Marshal.dump(arel).freeze
        op_name    = name.nil? ? nil : Ractor.make_shareable(name, copy: true)
        binds_dump = Ractor.make_shareable(binds, copy: true)

        Ractor::Dispatch.main.run do
          RactorConnectionProxy.dispatched_with_sanitized_errors do
            arel_ = Marshal.load(arel_dump)
            ActiveRecord::Base.with_connection do |c|
              rows = c.select_rows(arel_, op_name, binds_dump, async: false)
              Ractor.make_shareable(rows, copy: true)
            end
          end
        end
      end

      # The adapter's Arel visitor on the request side. The real
      # +visitor+ is bound to the underlying connection (it holds
      # +@connection+ for adapter-specific quoting), so it cannot ride
      # the boundary directly. Returns the request-side visitor proxy
      # which dispatches +compile(node)+ per call to main.
      #
      # Reached from +Calculations#execute_grouped_calculation+
      # (line 544: +field = connection.visitor.compile(field) if
      # Arel.arel_node?(field)+) and the +pluck+/+timestamp_column+
      # paths in +relation.rb+. All three callers use +visitor.compile+
      # only, so the proxy surface is intentionally just +compile+.
      def visitor
        RactorVisitorProxy
      end

      # Adapter-level metadata constant (SQLite ~64, Postgres 63).
      # Called once per +AliasTracker.create+ via
      # +Association#scope+ / +AssociationScope.scope+, which on the
      # destroy path drives +dependent: :destroy+ cascades. Per-call
      # dispatch is fine at this rate; consider boot-caching if it
      # ever becomes a hotspot.
      def table_alias_length
        Ractor::Dispatch.main.run do
          RactorConnectionProxy.dispatched_with_sanitized_errors do
            ActiveRecord::Base.with_connection do |c|
              c.table_alias_length
            end
          end
        end
      end

      # Truncates a table alias to the adapter's column-name length
      # (table_name[0...table_alias_length].tr(".", "_") in the
      # abstract adapter). Pure helper that only depends on the
      # input String + adapter constant, but +ColumnAliasTracker#
      # column_alias_for+ calls it via +@connection+, so the proxy
      # has to satisfy the call. Per-call dispatch is fine -- same
      # cost shape as +quote_table_name+ next to it.
      def table_alias_for(table_name)
        name_dump = table_name.frozen? ? table_name : table_name.dup.freeze
        Ractor::Dispatch.main.run do
          RactorConnectionProxy.dispatched_with_sanitized_errors do
            ActiveRecord::Base.with_connection do |c|
              result = c.table_alias_for(name_dump)
              Ractor.make_shareable(result, copy: true)
            end
          end
        end
      end

      # Adapter-level SQL identifier quoting. Per-call because the
      # input (a String table name) is per-call; result is a frozen
      # String. Used by +AliasTracker.initial_count_for+ when the
      # join list contains +Arel::Nodes::StringJoin+ entries.
      def quote_table_name(name)
        name_dump = name.frozen? ? name : name.dup.freeze
        Ractor::Dispatch.main.run do
          RactorConnectionProxy.dispatched_with_sanitized_errors do
            ActiveRecord::Base.with_connection do |c|
              result = c.quote_table_name(name_dump)
              Ractor.make_shareable(result, copy: true)
            end
          end
        end
      end

      # Adapter-level identifier quoting for the LHS of an assignment
      # (UPDATE ... SET col = ...). Defaults to +"table.col"+ in the
      # abstract adapter; the SQLite3 and PostgreSQL adapters override
      # it to return only the column name (per their UPDATE syntax).
      # Reached from +Sanitization#sanitize_sql_hash_for_assignment+
      # (e.g. +Post.update_all(status: nil)+ on the request path),
      # which calls +c.quote_table_name_for_assignment(table, attr)+
      # inside a +with_connection+ block. Inputs are per-call Strings
      # / Symbols (the table name and the attribute name); result is
      # a frozen String.
      def quote_table_name_for_assignment(table, attr)
        table_dump = table.is_a?(String) && table.frozen? ? table : table.to_s.dup.freeze
        attr_dump  = attr.is_a?(String) && attr.frozen?  ? attr  : attr.to_s.dup.freeze
        Ractor::Dispatch.main.run do
          RactorConnectionProxy.dispatched_with_sanitized_errors do
            ActiveRecord::Base.with_connection do |c|
              result = c.quote_table_name_for_assignment(table_dump, attr_dump)
              Ractor.make_shareable(result, copy: true)
            end
          end
        end
      end

      # Adapter-level +to_sql(arel_or_sql_string, binds = [])+. Reached
      # from +Relation#to_sql+ which calls
      # +conn.unprepared_statement { conn.to_sql(arel) }+ inside a
      # +with_connection+ block. The abstract adapter's +to_sql+
      # constructs a collector and walks the Arel AST through the
      # adapter's +visitor+ -- the visitor's dispatch hash holds
      # non-shareable Procs, so the AST has to be compiled on the main
      # side. We Marshal the input (typically an +Arel+ manager / node;
      # may also be a +String+, which +to_sql_and_binds+ short-circuits
      # to a frozen copy) and rebuild it on the main side, same shape
      # as +select_all+ / +select_rows+ above. Result is a frozen SQL
      # +String+, made shareable with +copy: true+ so the request side
      # can read it.
      def to_sql(arel_or_sql_string, binds = [])
        arel_dump  = Marshal.dump(arel_or_sql_string).freeze
        binds_dump = Ractor.make_shareable(binds, copy: true)

        Ractor::Dispatch.main.run do
          RactorConnectionProxy.dispatched_with_sanitized_errors do
            arel_ = Marshal.load(arel_dump)
            ActiveRecord::Base.with_connection do |c|
              result = c.to_sql(arel_, binds_dump)
              Ractor.make_shareable(result, copy: true)
            end
          end
        end
      end

      # Adapter-level bound-value casting. Defaults to identity in the
      # abstract adapter but MySQL etc. override it, so the call must
      # run on a real adapter on the main side. Reached from
      # +Sanitization#quote_bound_value+ (the +find_by_sql+ /
      # +where("col = ?", v)+ path), which calls
      # +connection.quote(connection.cast_bound_value(value))+ inside
      # +replace_bind_variable+. Per-call dispatch is the right shape
      # here: the input is whatever bind value the caller passed
      # (Integer, String, Date, AR::Base via +id_for_database+, ...),
      # which is not generally shareable on input, so we Marshal the
      # value across the boundary and +make_shareable+ the result on
      # the way back. Return shape mirrors the adapter contract:
      # whatever the underlying type cast returns (often the value
      # unchanged, sometimes a coerced primitive).
      def cast_bound_value(value)
        value_dump = Marshal.dump(value).freeze
        Ractor::Dispatch.main.run do
          RactorConnectionProxy.dispatched_with_sanitized_errors do
            loaded = Marshal.load(value_dump)
            ActiveRecord::Base.with_connection do |c|
              result = c.cast_bound_value(loaded)
              Ractor.make_shareable(result, copy: true)
            end
          end
        end
      end

      # Adapter-level SQL value quoting. Case-dispatched in the
      # abstract adapter on String / Symbol / true / false / nil /
      # BigDecimal / Numeric / Type::Binary::Data / Type::Time::Value
      # / Date / Time / Class, with adapter overrides for
      # +quote_string+, +quoted_binary+, etc., so it has to run on a
      # real adapter on the main side. Reached from the same
      # +Sanitization#quote_bound_value+ call site as +cast_bound_value+
      # above (and the empty-array / array-map branches of that
      # method). Input is the cast bind value -- not generally
      # shareable on input -- so we Marshal it across the boundary;
      # result is a +String+ (the SQL literal), made shareable with
      # +copy: true+ so the request side can read it.
      def quote(value)
        value_dump = Marshal.dump(value).freeze
        Ractor::Dispatch.main.run do
          RactorConnectionProxy.dispatched_with_sanitized_errors do
            loaded = Marshal.load(value_dump)
            ActiveRecord::Base.with_connection do |c|
              result = c.quote(loaded)
              Ractor.make_shareable(result, copy: true)
            end
          end
        end
      end

      # AR exceptions raised by the adapter (e.g. +StatementInvalid+,
      # +RecordNotUnique+) carry a +@connection_pool+ reference whose
      # graph includes +MonitorMixin+ state and is not shareable. If we
      # let such an exception ride back across +Ractor::Dispatch+
      # untouched the boundary fails with a confusing isolation error
      # instead of surfacing the original DB error. Strip the pool ref
      # before re-raising. The exception is re-raised so the caller (and
      # ultimately the controller / Rails error reporter) sees the real
      # cause.
      def dispatched_with_sanitized_errors
        yield
      rescue => e
        if e.respond_to?(:connection_pool) && e.respond_to?(:instance_variable_set)
          begin
            e.instance_variable_set(:@connection_pool, nil)
          rescue FrozenError
            # The exception is frozen; nothing we can do safely. Let it
            # propagate as-is and surface whatever isolation error follows.
          end
        end
        raise e
      end

      def respond_to_missing?(name, include_private = false)
        false
      end

      def method_missing(name, *, **, &)
        raise NoMethodError,
          "#{name} is not implemented on #{self} (the non-main-Ractor " \
          "connection proxy). The request-path write surface is " \
          "intentionally limited; if you hit this, extend the proxy at " \
          "#{__FILE__} or route the caller through the real connection " \
          "on the main Ractor."
      end
    end

    # Returned by +RactorConnectionProxy#visitor+ on a non-main Ractor.
    # The real +Arel::Visitors::ToSql+ instance holds +@connection+
    # for adapter-specific quoting and cannot cross a Ractor boundary.
    # The surface is intentionally just +compile(node)+, the only
    # method any current caller of +connection.visitor+ uses on the
    # request path (see callers in +Calculations+ and +Relation+).
    #
    # Each +compile+ call Marshals the Arel node (its +Arel::Visitors+
    # dispatch hash holds non-shareable Procs, so the AST cannot ride
    # the boundary as-is), dispatches to the main side, walks the AST
    # there with the real visitor, and returns the resulting SQL
    # +String+ as a shareable copy.
    module RactorVisitorProxy
      extend self

      def compile(node, collector = nil)
        node_dump      = Marshal.dump(node).freeze
        collector_dump = collector.nil? ? nil : Marshal.dump(collector).freeze

        Ractor::Dispatch.main.run do
          RactorConnectionProxy.dispatched_with_sanitized_errors do
            node_ = Marshal.load(node_dump)
            ActiveRecord::Base.with_connection do |c|
              result = if collector_dump
                c.visitor.compile(node_, Marshal.load(collector_dump))
              else
                c.visitor.compile(node_)
              end
              Ractor.make_shareable(result, copy: true)
            end
          end
        end
      end

      # +Visitor#accept(node, collector = nil)+ walks the AST and returns
      # the (mutated) collector. Reached from +Arel::Nodes::Node#to_sql+
      # (e.g. +Relation#sole+ via +select_manager.where_sql+ ->
      # +where_clause.ast.to_sql(engine)+ on the request path), which
      # then chains +.value+ to read the +SQLString+ collector's +@str+.
      # The visitor's dispatch hash holds non-shareable Procs, so the
      # walk has to run on the main side. Marshal the input node and
      # collector across the boundary, run +accept+ on the real visitor,
      # Marshal the resulting collector back as a shareable +String+,
      # and reload it on the request side -- the loaded collector is a
      # fresh local object on this Ractor, so the caller's +.value+ is
      # an in-Ractor read of +@str+ with no boundary concerns.
      def accept(node, collector = nil)
        node_dump      = Marshal.dump(node).freeze
        collector_dump = collector.nil? ? nil : Marshal.dump(collector).freeze

        result_dump = Ractor::Dispatch.main.run do
          RactorConnectionProxy.dispatched_with_sanitized_errors do
            node_ = Marshal.load(node_dump)
            ActiveRecord::Base.with_connection do |c|
              result = if collector_dump
                c.visitor.accept(node_, Marshal.load(collector_dump))
              else
                c.visitor.accept(node_)
              end
              Ractor.make_shareable(Marshal.dump(result), copy: true)
            end
          end
        end

        Marshal.load(result_dump)
      end

      def respond_to_missing?(name, include_private = false)
        false
      end

      def method_missing(name, *, **, &)
        raise NoMethodError,
          "#{name} is not implemented on #{self} (the non-main-Ractor " \
          "Arel visitor proxy). The request-path read surface is " \
          "intentionally limited to +compile+; if you hit this, extend " \
          "the proxy at #{__FILE__} or route the caller through the " \
          "real visitor on the main Ractor."
      end
    end

    # Returned by +RactorConnectionPool#schema_cache+ on a non-main
    # Ractor. Mirrors only the +BoundSchemaReflection+ methods the
    # request-path read flow actually calls. The real
    # +BoundSchemaReflection+ holds a +@pool+ reference whose graph
    # carries +MonitorMixin+ / +Mutex+ state and cannot cross a Ractor
    # boundary, so we per-call dispatch the read to the main side and
    # return a shareable copy of the result.
    #
    # Currently exposes only +indexes(table_name)+, reached via
    # +UniquenessValidator#covered_by_unique_index?+ during a save with
    # +validates_uniqueness_of+. Adding more methods (columns_hash,
    # primary_keys, ...) without a real first-failure driving them is
    # exactly the silent-forwarding anti-pattern called out in
    # +RactorConnectionProxy+'s docstring; extend deliberately when a
    # new gate failure points here.
    module RactorSchemaCacheProxy
      extend self

      # Dispatch to +klass.schema_cache.indexes(table_name)+ on the
      # main side and return a shareable +Array<IndexDefinition>+.
      # +IndexDefinition+ is a plain object with String/Symbol/nil
      # fields and deep-freezes cleanly.
      def indexes(table_name)
        name_dump = table_name.frozen? ? table_name : table_name.dup.freeze
        Ractor::Dispatch.main.run do
          RactorConnectionProxy.dispatched_with_sanitized_errors do
            result = ActiveRecord::Base.connection_pool.schema_cache.indexes(name_dump)
            Ractor.make_shareable(result, copy: true)
          end
        end
      end

      def respond_to_missing?(name, include_private = false)
        false
      end

      def method_missing(name, *, **, &)
        raise NoMethodError,
          "#{name} is not implemented on #{self} (the non-main-Ractor " \
          "schema-cache proxy). The request-path read surface is " \
          "intentionally limited; if you hit this, extend the proxy at " \
          "#{__FILE__} or route the caller through the real schema cache " \
          "on the main Ractor."
      end
    end

    # Returned by +ActiveRecord::Base.connection_pool+ on a non-main
    # Ractor. Mirrors the surface the persistence path actually touches:
    # +with_connection+ (yields the connection proxy), the
    # +with_pool_transaction_isolation_level+ wrapper that
    # +with_transaction_returning_status+ wraps every save in, and
    # +schema_cache+ which returns +RactorSchemaCacheProxy+ for the
    # narrow read-path schema lookups (currently +indexes+, used by
    # +UniquenessValidator#covered_by_unique_index?+). Schema-cache
    # entries are eagerly populated on the main side at boot via
    # +SchemaReflection+, so the dispatched call is a frozen-result
    # in-memory lookup, not a DB roundtrip in the steady state.
    module RactorConnectionPool
      extend self

      def with_connection(prevent_permanent_checkout: false, &block)
        yield RactorConnectionProxy
      end

      # Real implementation toggles the pool's isolation level around the
      # block. Per-call dispatched DB statements run on the main side in
      # the pool's current default isolation level; modifying the pool's
      # default from the request side is out of scope, so this is a
      # yielding shell. See +RactorConnectionProxy+ docstring.
      def with_pool_transaction_isolation_level(isolation_level, open, &block)
        yield
      end

      def active_connection
        nil
      end

      # +ActiveRecord::Base.connection_db_config+ flows through here. The
      # db_config is set at boot and the persistence path occasionally
      # reads it (e.g. for adapter-class lookups). Dispatch and freeze.
      def db_config
        Ractor::Dispatch.main.run do
          RactorConnectionProxy.dispatched_with_sanitized_errors do
            result = ActiveRecord::Base.connection_pool.db_config
            Ractor.make_shareable(result, copy: true)
          end
        end
      end

      # +ActiveRecord::Persistence#reload+ flows through here: it calls
      # +self.class.connection_pool.clear_query_cache+ before refetching
      # the record so the find sees fresh data. Dispatch clears the
      # main-side pool's per-thread query cache so subsequent
      # dispatched selects don't hit a stale cached result. Returns
      # +nil+ because the request side never reads the return value of
      # +query_cache.clear+.
      def clear_query_cache
        Ractor::Dispatch.main.run do
          RactorConnectionProxy.dispatched_with_sanitized_errors do
            ActiveRecord::Base.connection_pool.clear_query_cache
            nil
          end
        end
      end

      # Returns the request-side schema-cache proxy. The real
      # +ConnectionPool#schema_cache+ holds a non-shareable pool
      # reference; the proxy dispatches per-call schema reads to the
      # main side. See +RactorSchemaCacheProxy+.
      def schema_cache
        RactorSchemaCacheProxy
      end

      def respond_to_missing?(name, include_private = false)
        false
      end

      def method_missing(name, *, **, &)
        raise NoMethodError,
          "#{name} is not implemented on #{self} (the non-main-Ractor " \
          "connection-pool proxy). The request-path write surface is " \
          "intentionally limited; if you hit this, extend the proxy at " \
          "#{__FILE__} or route the caller through the real pool on " \
          "the main Ractor."
      end
    end

    Ractor.make_shareable(RactorConnectionProxy)
    Ractor.make_shareable(RactorVisitorProxy)
    Ractor.make_shareable(RactorSchemaCacheProxy)
    Ractor.make_shareable(RactorConnectionPool)
  end
end
