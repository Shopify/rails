# frozen_string_literal: true

# :markup: markdown

require "ractor/dispatch"
require "active_record/connection_adapters/ractor_connection_proxy/query_request"
require "active_record/connection_adapters/ractor_connection_proxy/query_response"
require "active_record/connection_adapters/ractor_connection_proxy/visitor_proxy"

module ActiveRecord
  module ConnectionAdapters
    # Worker-Ractor stand-in for a concrete adapter. It runs the ordinary
    # worker-side query pipeline locally and forwards everything else to a
    # token-pinned physical connection on the main Ractor.
    class RactorConnectionProxy < AbstractAdapter # :nodoc:
      ADAPTER_NAME = "RactorProxy"

      CAPABILITY_METHOD_PATTERN = /\Asupports_.*\?\z/
      PLACEHOLDER_LOGGER = Object.new.freeze

      # Raised on the worker when the main-side error class cannot be
      # reconstructed. Preserves the original class name.
      class RemoteError < ActiveRecordError
        attr_reader :remote_class_name

        def initialize(message, remote_class_name)
          @remote_class_name = remote_class_name
          super(message)
        end
      end

      # Shareable response describing a main-side failure. The worker
      # reconstructs and raises the original exception class from it.
      class ErrorResponse
        attr_reader :class_name, :message, :sql, :backtrace

        def initialize(error, sql: nil)
          @class_name = error.class.name.to_s
          @message = error.message.to_s
          @sql = ((error.respond_to?(:sql) && error.sql) || sql)&.to_s
          @backtrace = error.backtrace
          ActiveSupport::Ractors.make_shareable(self, copy: false)
        rescue Ractor::Error
          @backtrace = nil
          ActiveSupport::Ractors.make_shareable(self, copy: false)
        end
      end

      # Main-Ractor-only registry of token-pinned physical connections.
      @connections = {}
      @next_connection_id = 0
      @connections_lock = Mutex.new

      # Main-Ractor-only cache of computed per-adapter-class transport
      # surfaces.
      @remote_adapter_methods = {}.compare_by_identity

      class << self
        attr_reader :connections

        def checkout_connection(connection_name, role, shard)
          shareable_connection_name = shareable_copy(connection_name.to_s)
          main_operation do
            connection = main_pool(shareable_connection_name, role, shard).checkout
            token = register_connection(connection)
            ActiveSupport::Ractors.make_shareable([token, connection_profile(connection)], copy: true)
          end
        end

        def checkin_connection(connection_token)
          main_operation do
            if connection = take_back_connection(connection_token)
              connection.pool.checkin(connection)
            end
            nil
          end
        end

        # Backs `AbstractAdapter#throw_away!` on the worker.
        def remove_connection(connection_token)
          main_operation do
            if connection = take_back_connection(connection_token)
              connection.pool.remove(connection)
              connection.disconnect!
            end
            nil
          end
        end

        def discard_connection(connection_token)
          main_operation do
            if connection = take_back_connection(connection_token)
              connection.pool.remove(connection)
              connection.discard!
            end
            nil
          end
        end

        # External lifecycle hook: releases every token-pinned connection.
        # Intended for supervisors that tear down worker Ractors, since a
        # worker that dies abruptly cannot release its own tokens.
        def checkin_all_connections
          main_operation do
            @connections_lock.synchronize do
              @connections.each_value do |connection|
                reclaim(connection)
                connection.pool.checkin(connection)
              end
              @connections.clear
            end
            nil
          end
        end

        def main_pool_specs(role = nil)
          main_operation do
            specs = connection_handler.connection_pool_list(role).map do |pool|
              RactorConnectionPool.spec_for(pool)
            end
            ActiveSupport::Ractors.make_shareable(specs, copy: false)
          end
        end

        def main_pool_spec(connection_name, role, shard, strict)
          shareable_connection_name = shareable_copy(connection_name.to_s)
          main_operation do
            pool = connection_handler.retrieve_connection_pool(
              shareable_connection_name,
              role: role,
              shard: shard,
              strict: strict,
            )
            pool && RactorConnectionPool.spec_for(pool)
          end
        end

        def dispatch_to_main_pool(connection_name, role, shard, method_name, args, kwargs, connection_pool: nil)
          shareable_connection_name = shareable_copy(connection_name.to_s)
          shareable_args = shareable_copy(args)
          shareable_kwargs = shareable_copy(kwargs)
          dispatched_method = method_name.to_sym

          main_operation(connection_pool: connection_pool) do
            result = main_pool(shareable_connection_name, role, shard)
              .__send__(dispatched_method, *shareable_args, **shareable_kwargs)
            shareable_copy(result)
          end
        end

        def dispatch_to_main_schema_cache(connection_name, role, shard, method_name, args, kwargs, connection_pool: nil)
          shareable_connection_name = shareable_copy(connection_name.to_s)
          shareable_args = shareable_copy(args)
          shareable_kwargs = shareable_copy(kwargs)
          dispatched_method = method_name.to_sym

          main_operation(connection_pool: connection_pool) do
            schema_cache = main_pool(shareable_connection_name, role, shard).schema_cache
            shareable_copy(schema_cache.__send__(dispatched_method, *shareable_args, **shareable_kwargs))
          end
        end

        # Generic dispatch of one adapter method to the token-pinned connection.
        def call_connection(connection_token, method_name, args, kwargs, connection_pool: nil)
          shareable_args = shareable_copy(args)
          shareable_kwargs = shareable_copy(kwargs)
          dispatched_method = method_name.to_sym

          main_operation(connection_pool: connection_pool) do
            connection = fetch_connection(connection_token)
            shareable_copy(connection.__send__(dispatched_method, *shareable_args, **shareable_kwargs))
          end
        end

        # The deliberate low-level query operation. Executes below the public
        # query pipeline: no main-side intent logging, no query transformers,
        # no main-side transaction bookkeeping — only connection readiness,
        # the concrete adapter's `perform_query`, and result materialization.
        def query_connection(connection_token, request, connection_pool: nil)
          main_operation(sql: request.sql, connection_pool: connection_pool) do
            perform_main_query(fetch_connection(connection_token), request)
          end
        end

        def cast_binds_on_connection(connection_token, binds_payload, connection_pool: nil)
          main_operation(connection_pool: connection_pool) do
            connection = fetch_connection(connection_token)
            shareable_copy(connection.type_casted_binds(Marshal.load(binds_payload)))
          end
        end

        # Compiles an Arel AST with the concrete adapter's `to_sql_and_binds`,
        # preserving its prepared-statement, collector, and retryability
        # semantics. Returns `[sql, binds_payload, preparable, allow_retry]`.
        def compile_on_connection(connection_token, ast_payload, preparable, allow_retry, connection_pool: nil)
          main_operation(connection_pool: connection_pool) do
            connection = fetch_connection(connection_token)
            sql, binds, compiled_preparable, compiled_allow_retry =
              connection.to_sql_and_binds(Marshal.load(ast_payload), [], preparable, allow_retry)
            ActiveSupport::Ractors.make_shareable(
              [sql, Marshal.dump(binds), compiled_preparable, compiled_allow_retry], copy: true
            )
          end
        end

        # Compiles an Arel node with the concrete adapter's visitor and the
        # caller's collector, reconstructed on the main Ractor. Returns
        # `[value_payload, preparable, retryable]`.
        def visitor_compile_on_connection(connection_token, node_payload, collector_payload, connection_pool: nil)
          main_operation(connection_pool: connection_pool) do
            connection = fetch_connection(connection_token)
            node = Marshal.load(node_payload)
            collector =
              case collector_payload
              when nil then Arel::Collectors::SQLString.new
              when :substitute_binds
                Arel::Collectors::SubstituteBinds.new(connection, Arel::Collectors::SQLString.new)
              else
                Marshal.load(collector_payload)
              end
            value = connection.visitor.compile(node, collector)
            preparable = collector.preparable if collector.respond_to?(:preparable)
            retryable = collector.retryable if collector.respond_to?(:retryable)
            ActiveSupport::Ractors.make_shareable([Marshal.dump(value), preparable, retryable], copy: true)
          end
        end

        # Methods that must keep their (worker-local) AbstractAdapter
        # implementations even when a concrete adapter overrides them: the
        # query pipeline entry points (which must build worker-side intents),
        # exception translation (main-side errors arrive pre-translated), and
        # physical connection machinery that only makes sense next to the raw
        # connection on the main Ractor.
        ALWAYS_LOCAL_METHODS = %i[
          execute exec_query exec_insert exec_delete exec_update exec_insert_all
          _exec_insert insert update delete truncate truncate_tables execute_batch
          select_all select_one select_value select_values select_rows
          query_all query_rows query_values query_value query_one query_command
          cacheable_query to_sql to_sql_and_binds
          translate_exception translate_exception_class retryable_query_error?
          type_map extended_type_map_key
          reconnect connect! configure_connection attempt_configure_connection
          check_version default_prepared_statements
        ].freeze

        # Per-Ractor cache of the remote-dispatch modules built from a connection profile.
        def remote_dispatch_module(profile)
          cache = (ActiveSupport::Ractors[:active_record_ractor_dispatch_modules] ||= {})
          cache[profile[:adapter_class_name]] ||= Module.new do
            profile[:remote_methods].each do |method_name|
              define_method(method_name) do |*args, **kwargs, &block|
                if block
                  raise ActiveRecordError,
                    "Cannot forward a block to #{method_name} on the main-Ractor connection"
                end
                remote_adapter_call(method_name, args, kwargs)
              end
            end
          end
        end

        # Only public because `on_main` blocks run with a nil `self`.
        def capture_transport_errors(sql: nil) # :nodoc:
          yield
        rescue => error
          ErrorResponse.new(error, sql: sql)
        end

        def raise_transport_error(response, connection_pool: nil) # :nodoc:
          klass = begin
            constant = Object.const_get(response.class_name)
            constant if constant.is_a?(Class) && constant <= Exception
          rescue NameError
            nil
          end

          error =
            begin
              if klass && klass <= ActiveRecord::StatementInvalid
                klass.new(response.message, sql: response.sql, connection_pool: connection_pool)
              elsif klass && klass <= ActiveRecord::AdapterError
                klass.new(response.message, connection_pool: connection_pool)
              elsif klass
                klass.new(response.message)
              end
            rescue ArgumentError, TypeError
              nil
            end

          error ||= RemoteError.new("#{response.class_name}: #{response.message}", response.class_name)
          error.set_backtrace(response.backtrace) if response.backtrace
          raise error
        end

        def shareable_copy(value)
          return value if ActiveSupport::Ractors.shareable?(value)

          copy = Marshal.load(Marshal.dump(value))
          ActiveSupport::Ractors.make_shareable(copy)
        end

        def dump_object(value, description)
          Marshal.dump(value).freeze
        rescue TypeError => error
          raise ActiveRecordError, "Cannot send #{description} across the Ractor boundary: #{error.message}"
        end

        def dump_binds(binds)
          return nil if binds.nil? || binds.empty?

          dump_object(binds, "bind parameters")
        end

        def dump_column_types(result)
          types = result.columns.map { |name| result.column_types[name] }
          return nil if types.all?(&:nil?)

          begin
            Marshal.dump(types).freeze
          rescue TypeError
            # Drop only the unmarshalable entries; `ActiveRecord::Result`
            # falls back to `Type.default_value` for nil entries.
            safe_types = types.map do |type|
              Marshal.dump(type)
              type
            rescue TypeError
              nil
            end
            Marshal.dump(safe_types).freeze
          end
        end

        private
          # Runs `block` on the main Ractor with `self` pinned to this class.
          # The block must capture only shareable objects and return a
          # shareable value. A main-side error travels back as an
          # ErrorResponse and is re-raised on the calling side.
          def main_operation(sql: nil, connection_pool: nil, &block)
            operation =
              if ActiveSupport::Ractors.main?
                block
              else
                ActiveSupport::Ractors.shareable_proc(self: RactorConnectionProxy, &block)
              end

            outcome = ActiveSupport::Ractors.on_main do
              RactorConnectionProxy.capture_transport_errors(sql: sql) { operation.call }
            end
            unwrap_transport_outcome(outcome, connection_pool: connection_pool)
          end

          def unwrap_transport_outcome(outcome, connection_pool: nil)
            raise_transport_error(outcome, connection_pool: connection_pool) if outcome.is_a?(ErrorResponse)
            outcome
          end

          def register_connection(connection)
            connection.connect!
            # Not folded into connect! (the shared bootstrap for every
            # adapter): only this callsite knows the connection is being
            # pinned. steal! clears the flag when the lease is taken back.
            connection.reconnect = true
            @connections_lock.synchronize do
              token = (@next_connection_id += 1)
              @connections[token] = connection
              token
            end
          end

          def deregister_connection(connection_token)
            @connections_lock.synchronize { @connections.delete(connection_token) }
          end

          def take_back_connection(connection_token)
            if connection = deregister_connection(connection_token)
              reclaim(connection)
              connection
            end
          end

          def fetch_connection(connection_token)
            connection = @connections_lock.synchronize { @connections[connection_token] }
            unless connection
              raise ConnectionNotEstablished, "The Ractor-pinned connection for token #{connection_token.inspect} has been released"
            end
            connection
          end

          # Token-pinned connections are leased on whichever thread ran the
          # checkout operation (usually the dispatch executor). Reassign
          # ownership to the current thread so pool checkin/removal is legal
          # from any main-Ractor thread.
          def reclaim(connection)
            connection.steal! if connection.in_use?
          end

          def perform_main_query(connection, request)
            binds = request.binds_payload ? Marshal.load(request.binds_payload) : []
            intent = QueryIntent.new(
              adapter: connection,
              processed_sql: request.sql,
              name: request.name,
              binds: binds,
              prepare: request.prepare,
              allow_retry: request.allow_retry,
              materialize_transactions: false,
              batch: request.batch,
            )
            # Concrete `perform_query` implementations record row counts here.
            intent.notification_payload = {}

            result, warnings, last_inserted_id = connection.execute_raw_intent(intent)

            QueryResponse.new(
              result,
              intent.notification_payload[:affected_rows] || result.affected_rows,
              intent.notification_payload[:row_count] || result.length,
              last_inserted_id,
              warnings,
            )
          end

          def connection_handler
            ActiveRecord::Base.connection_handler
          end

          def main_pool(connection_name, role, shard)
            connection_handler.retrieve_connection_pool(
              connection_name,
              role: role,
              shard: shard,
              strict: true,
            )
          end

          def connection_profile(connection)
            klass = connection.class
            {
              adapter_class_name: klass.name,
              adapter_name: connection.adapter_name,
              prepared_statements: connection.instance_variable_get(:@prepared_statements),
              remote_methods: remote_adapter_methods(klass),
            }
          end

          # The computed transport surface for one concrete adapter class:
          # every method the concrete class overrides from AbstractAdapter —
          # instance-level, or class-level behind an instance delegator (e.g.
          # `quote_column_name`) — minus the worker pipeline/lifecycle methods
          # the proxy implements itself.
          def remote_adapter_methods(klass)
            @remote_adapter_methods[klass] ||= begin
              base = AbstractAdapter
              boundary = local_boundary_methods

              instance_candidates = (
                base.instance_methods + base.protected_instance_methods + base.private_instance_methods
              ).uniq
              overridden = instance_candidates.select do |name|
                !boundary.include?(name) &&
                  klass.instance_method(name).owner != base.instance_method(name).owner
              end

              class_candidates = (base.methods + base.protected_methods + base.private_methods).uniq
              class_overridden = class_candidates.select do |name|
                next false if boundary.include?(name)
                next false unless base.method_defined?(name) || base.private_method_defined?(name) ||
                  base.protected_method_defined?(name)
                begin
                  klass.method(name).owner != base.method(name).owner
                rescue NameError
                  false
                end
              end

              ActiveSupport::Ractors.make_shareable((overridden | class_overridden).sort)
            end
          end

          def local_boundary_methods
            @local_boundary_methods ||= (
              RactorConnectionProxy.instance_methods(false) +
              RactorConnectionProxy.protected_instance_methods(false) +
              RactorConnectionProxy.private_instance_methods(false) +
              ALWAYS_LOCAL_METHODS
            ).to_set.freeze
          end
      end

      def initialize(pool, connection_token, profile, config)
        super(nil, PLACEHOLDER_LOGGER, nil, config)
        @connection_token = connection_token
        @logger = nil
        @pool = pool
        @adapter_profile = profile
        @prepared_statements = profile[:prepared_statements]
        @raw_connection = connection_token
        @verified = true
        @remote_capability_memo = {}
        @quoted_column_names = {}
        @quoted_table_names = {}
        @last_query_response = nil
        extend(self.class.remote_dispatch_module(profile))
      end

      def adapter_name
        @adapter_profile[:adapter_name]
      end

      # Whether this proxy still holds a token-pinned main-side connection.
      # For the state of the underlying physical connection, use #active?.
      def connected?
        !@connection_token.nil?
      end

      def active?
        connected? && !!remote_adapter_call(:active?)
      end

      def verify!
        remote_adapter_call(:verify!)
        @verified = true
        self
      end

      def connect!
        unless connected?
          raise ConnectionNotEstablished, "The Ractor-pinned connection has been released"
        end
        verify!
      end

      def reconnect!(restore_transactions: false)
        remote_adapter_call(:reconnect!, [], { restore_transactions: restore_transactions })
        @verified = true
        self
      end

      def disconnect!
        if @connection_token
          begin
            remote_adapter_call(:disconnect!)
          ensure
            release_connection
          end
        end
        reset_transaction
      end

      def discard!
        if token = @connection_token
          @connection_token = nil
          @raw_connection = nil
          self.class.discard_connection(token)
        end
        reset_transaction
      end

      def reset!
        remote_adapter_call(:reset!)
        reset_transaction
        self
      end

      def release_connection
        if token = @connection_token
          @connection_token = nil
          @raw_connection = nil
          self.class.checkin_connection(token)
        end
      end

      # Backs RactorConnectionPool#remove (AbstractAdapter#throw_away!).
      def remove_connection
        if token = @connection_token
          @connection_token = nil
          @raw_connection = nil
          self.class.remove_connection(token)
        end
      end

      def native_database_types
        remote_adapter_call(:native_database_types)
      end

      def valid_type?(type)
        !native_database_types[type].nil?
      end

      def quote_column_name(name)
        @quoted_column_names[name] ||= remote_adapter_call(:quote_column_name, [name])
      end

      def quote_table_name(name)
        @quoted_table_names[name] ||= remote_adapter_call(:quote_table_name, [name])
      end

      def type_casted_binds(binds)
        return [] if binds.nil? || binds.empty?

        self.class.cast_binds_on_connection(
          @connection_token, self.class.dump_binds(binds), connection_pool: @pool
        )
      end

      def to_sql_and_binds(arel_or_sql, binds = [], preparable = nil, allow_retry = false) # :nodoc:
        if arel_or_sql.respond_to?(:ast)
          arel_or_sql = arel_or_sql.ast
        end

        if Arel.arel_node?(arel_or_sql) && !(String === arel_or_sql)
          unless binds.empty?
            raise "Passing bind parameters with an arel AST is forbidden. " \
              "The values must be stored on the AST directly"
          end

          sql, binds_payload, compiled_preparable, compiled_allow_retry =
            self.class.compile_on_connection(
              @connection_token,
              self.class.dump_object(arel_or_sql, "an Arel AST"),
              preparable,
              allow_retry,
              connection_pool: @pool,
            )
          [sql, Marshal.load(binds_payload), compiled_preparable, compiled_allow_retry]
        else
          super
        end
      end

      # Raw driver results cannot cross the Ractor boundary; `execute`
      # returns a materialized ActiveRecord::Result instead.
      def execute(sql, name = nil, allow_retry: false)
        intent = internal_build_intent(sql, name, allow_retry: allow_retry)
        intent.execute!
        intent.cast_result
      end

      def remote_visitor_compile(node, collector) # :nodoc:
        collector_payload =
          case collector
          when nil
            nil
          when Arel::Collectors::SubstituteBinds
            :substitute_binds
          else
            self.class.dump_object(collector, "the Arel collector #{collector.class}")
          end

        value_payload, preparable, retryable = self.class.visitor_compile_on_connection(
          @connection_token,
          self.class.dump_object(node, "an Arel AST"),
          collector_payload,
          connection_pool: @pool,
        )

        if collector
          collector.preparable = preparable if collector.respond_to?(:preparable=) && !preparable.nil?
          collector.retryable = retryable if collector.respond_to?(:retryable=) && !retryable.nil?
        end
        Marshal.load(value_payload)
      end

      private
        def arel_visitor
          VisitorProxy.new(self)
        end

        def build_statement_pool
          # Prepared statements are managed by the concrete adapter on the
          # main Ractor.
          nil
        end

        def perform_query(_raw_connection, intent)
          request = QueryRequest.new(
            sql: intent.processed_sql,
            binds_payload: self.class.dump_binds(intent.binds),
            name: intent.name,
            prepare: intent.prepare,
            batch: intent.batch,
            allow_retry: intent.allow_retry,
          )

          response = self.class.query_connection(@connection_token, request, connection_pool: @pool)
          @last_query_response = response
          intent.notification_payload[:affected_rows] = response.affected_rows
          intent.notification_payload[:row_count] = response.row_count
          response
        end

        def cast_result(response)
          return response if response.is_a?(ActiveRecord::Result)

          response.to_result
        end

        def affected_rows(response)
          response.affected_rows
        end

        def collect_warnings(response)
          response.is_a?(QueryResponse) ? response.warnings : []
        end

        # The generated ID as computed by the concrete adapter on the main
        # Ractor right after the query (e.g. `last_id` for MySQL inserts
        # without RETURNING).
        def last_inserted_id(_result)
          @last_query_response&.last_inserted_id
        end

        def remote_adapter_call(method_name, args = [], kwargs = {})
          unless @connection_token
            raise ConnectionNotEstablished, "The Ractor-pinned connection has been released"
          end

          if args.empty? && kwargs.empty? && CAPABILITY_METHOD_PATTERN.match?(method_name)
            @remote_capability_memo.fetch(method_name) do
              @remote_capability_memo[method_name] =
                self.class.call_connection(@connection_token, method_name, args, kwargs, connection_pool: @pool)
            end
          else
            self.class.call_connection(@connection_token, method_name, args, kwargs, connection_pool: @pool)
          end
        end

        def method_missing(name, *args, **kwargs, &block)
          return super if name == :marshal_dump || name == :_dump

          if block
            raise ActiveRecordError, "Cannot forward a block to #{name} on the main-Ractor connection"
          end

          remote_adapter_call(name, args, kwargs)
        end

        def respond_to_missing?(name, include_private = false)
          return false if name == :marshal_dump || name == :_dump

          super
        end
    end
  end
end
