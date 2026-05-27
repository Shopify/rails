# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    class RactorConnectionProxy < AbstractAdapter # :nodoc:
      ADAPTER_NAME = "RactorProxy"

      MAIN_CONNECTIONS = {}
      MAIN_CONNECTIONS.compare_by_identity if MAIN_CONNECTIONS.respond_to?(:compare_by_identity)
      @next_token = 0

      class QueryRequest
        attr_reader :sql, :binds, :name, :prepare, :batch, :allow_retry, :materialize_transactions

        def initialize(sql:, binds:, name:, prepare:, batch:, allow_retry:, materialize_transactions:)
          @sql = RactorConnectionProxy.shareable_copy(sql)
          @binds = RactorConnectionProxy.shareable_copy(binds)
          @name = RactorConnectionProxy.shareable_copy(name || "SQL")
          @prepare = prepare
          @batch = batch
          @allow_retry = allow_retry
          @materialize_transactions = materialize_transactions
          Ractor.make_shareable(self)
        end
      end

      class QueryResponse
        attr_reader :columns, :rows, :column_types, :affected_rows

        def initialize(result)
          @columns = RactorConnectionProxy.shareable_copy(result.columns)
          @rows = RactorConnectionProxy.shareable_copy(result.rows)
          @column_types = {}.freeze
          @affected_rows = result.affected_rows
          Ractor.make_shareable(self)
        end

        def to_result
          ActiveRecord::Result.new(@columns, @rows, @column_types, affected_rows: @affected_rows)
        end
      end

      class << self
        def checkout_main_connection(connection_name, role, shard)
          shareable_connection_name = shareable_copy(connection_name.to_s)
          Ractor::Dispatch.main.run do
            pool = RactorConnectionProxy.main_pool(shareable_connection_name, role, shard)
            connection = pool.checkout
            connection_token = RactorConnectionProxy.next_token
            MAIN_CONNECTIONS[connection_token] = [pool, connection]
            connection_token
          end
        end

        def next_token
          @next_token = (@next_token || 0) + 1
          @next_token
        end

        def checkin_main_connection(connection_token)
          Ractor::Dispatch.main.run do
            if entry = MAIN_CONNECTIONS.delete(connection_token)
              pool, connection = entry
              pool.checkin(connection)
            end
            nil
          end
        end

        def main_pool_specs(role = nil)
          Ractor::Dispatch.main.run do
            RactorConnectionProxy.main_connection_handler.connection_pool_list(role).map do |pool|
              RactorConnectionPool.spec_for(pool)
            end
          end
        end

        def main_pool_spec(connection_name, role, shard, strict)
          shareable_connection_name = shareable_copy(connection_name.to_s)
          Ractor::Dispatch.main.run do
            pool = RactorConnectionProxy.main_connection_handler.retrieve_connection_pool(
              shareable_connection_name,
              role: role,
              shard: shard,
              strict: strict,
            )
            pool && RactorConnectionPool.spec_for(pool)
          end
        end

        def dispatch_to_main_pool(connection_name, role, shard, method_name, args, kwargs)
          shareable_connection_name = shareable_copy(connection_name.to_s)
          shareable_args = shareable_copy(args)
          shareable_kwargs = shareable_copy(kwargs)
          dispatched_method = method_name.to_sym

          Ractor::Dispatch.main.run do
            result = RactorConnectionProxy.main_pool(shareable_connection_name, role, shard).__send__(dispatched_method, *shareable_args, **shareable_kwargs)
            RactorConnectionProxy.shareable_copy(result)
          end
        end

        def dispatch_to_main_connection(connection_token, method_name, args = [], kwargs = {})
          shareable_args = shareable_copy(args)
          shareable_kwargs = shareable_copy(kwargs)
          dispatched_method = method_name.to_sym

          outcome = Ractor::Dispatch.main.run do
            _pool, connection = MAIN_CONNECTIONS.fetch(connection_token)
            begin
              result = connection.__send__(dispatched_method, *shareable_args, **shareable_kwargs)
              RactorConnectionProxy.shareable_copy(result)
            rescue => e
              [:error, e.class.name.to_s.freeze, e.message.to_s.freeze].freeze
            end
          end
          raise RuntimeError, outcome[2] if outcome.is_a?(Array) && outcome[0] == :error

          outcome
        end

        def dispatch_query(connection_token, request)
          outcome = Ractor::Dispatch.main.run do
            _pool, connection = MAIN_CONNECTIONS.fetch(connection_token)
            begin
              result = if request.batch
                connection.execute(request.sql, request.name, allow_retry: request.allow_retry)
              elsif request.prepare
                connection.exec_query(request.sql, request.name, request.binds, prepare: true)
              else
                connection.exec_query(request.sql, request.name, request.binds)
              end

              QueryResponse.new(result)
            rescue => e
              [:error, e.class.name.to_s.freeze, e.message.to_s.freeze].freeze
            end
          end
          raise RuntimeError, outcome[2] if outcome.is_a?(Array) && outcome[0] == :error

          outcome
        end

        def shareable_copy(value)
          return value if Ractor.shareable?(value)

          copy = begin
            Marshal.load(Marshal.dump(value))
          rescue Exception
            case value
            when Array
              value.map { |v| shareable_copy(v) }
            when Hash
              value.to_h { |k, v| [shareable_copy(k), shareable_copy(v)] }
            when String
              value.dup
            else
              if defined?(ActionText::Content) && value.is_a?(ActionText::Content)
                value.to_html.to_s
              elsif defined?(Nokogiri::XML::Node) && value.is_a?(Nokogiri::XML::Node)
                value.to_html.to_s
              elsif defined?(Nokogiri::XML::Document) && value.is_a?(Nokogiri::XML::Document)
                value.to_html.to_s
              else
                value.to_s
              end
            end
          end
          Ractor.make_shareable(copy)
        rescue Ractor::Error => e
          warn "[shareable_copy] #{value.class}: #{e.message}"
          case value
          when Array
            Ractor.make_shareable(value.map { |v| shareable_copy(v) })
          when Hash
            Ractor.make_shareable(value.to_h { |k, v| [shareable_copy(k), shareable_copy(v)] })
          else
            if defined?(ActionText::Content) && value.is_a?(ActionText::Content)
              Ractor.make_shareable(value.to_html.to_s)
            elsif defined?(Nokogiri::XML::Node) && value.is_a?(Nokogiri::XML::Node)
              Ractor.make_shareable(value.to_html.to_s)
            elsif defined?(Nokogiri::XML::Document) && value.is_a?(Nokogiri::XML::Document)
              Ractor.make_shareable(value.to_html.to_s)
            elsif value.respond_to?(:to_html)
              Ractor.make_shareable(value.to_html.to_s)
            else
              Ractor.make_shareable(value.to_s)
            end
          end
        end

        def main_connection_handler
          ActiveRecord::Base.connection_handler
        end

        def main_pool(connection_name, role, shard)
          main_connection_handler.retrieve_connection_pool(
            connection_name,
            role: role,
            shard: shard,
            strict: true,
          )
        end
      end

      DELEGATED_METHODS = %i[
        adapter_name native_database_types get_database_version database_version
        quote quote_string quote_column_name quote_table_name quote_table_name_for_assignment
        quoted_true quoted_false unquoted_true unquoted_false quote_default_expression
        lookup_cast_type type_to_sql build_insert_sql default_sequence_name empty_insert_statement_value
        supports_advisory_locks? supports_bulk_alter? supports_check_constraints?
        supports_comments? supports_comments_in_create? supports_common_table_expressions?
        supports_concurrent_connections? supports_datetime_with_precision?
        supports_ddl_transactions? supports_deferrable_constraints? supports_disabling_indexes?
        supports_exclusion_constraints? supports_explain? supports_expression_index?
        supports_extensions? supports_foreign_keys? supports_identity_columns?
        supports_index_include? supports_index_sort_order? supports_index_using?
        supports_indexes_in_create? supports_insert_on_conflict?
        supports_insert_on_duplicate_skip? supports_insert_on_duplicate_update?
        supports_insert_raw_alias_syntax? supports_insert_returning? supports_json?
        supports_lazy_transactions? supports_materialized_views? supports_native_partitioning?
        supports_nulls_not_distinct? supports_optimizer_hints? supports_partial_index?
        supports_partitioned_indexes? supports_rename_column? supports_rename_index?
        supports_restart_db_transaction? supports_savepoints? supports_transaction_isolation?
        supports_unique_constraints? supports_validate_constraints? supports_views?
        supports_virtual_columns?
      ].freeze

      DELEGATED_METHODS.each do |method_name|
        delegated_method_name = method_name
        define_method(delegated_method_name,
          ->(*args, **kwargs) {
            self.class.dispatch_to_main_connection(@main_connection_token, delegated_method_name, args, kwargs)
          }.make_shareable!)
      end

      def initialize(pool, main_connection_token, config)
        super(config)
        @pool = pool
        @main_connection_token = main_connection_token.freeze
        @raw_connection = @main_connection_token
        @verified = true
        @visitor = ActiveRecord::ConnectionHandling::RactorVisitorProxy.instance if defined?(ActiveRecord::ConnectionHandling::RactorVisitorProxy)
      end

      def connected?
        @raw_connection.present?
      end

      def active?
        connected?
      end

      def verify!
        @verified = true
        self
      end

      def reconnect!
        verify!
      end

      def disconnect!
        release_main_connection
      end

      def release_main_connection
        self.class.checkin_main_connection(@main_connection_token) if @main_connection_token
      end

      def begin_db_transaction
        self.class.dispatch_to_main_connection(@main_connection_token, __method__)
      end

      def begin_isolated_db_transaction(isolation)
        self.class.dispatch_to_main_connection(@main_connection_token, __method__, [isolation])
      end

      def commit_db_transaction
        self.class.dispatch_to_main_connection(@main_connection_token, __method__)
      end

      def exec_rollback_db_transaction
        self.class.dispatch_to_main_connection(@main_connection_token, __method__)
      end

      def restart_db_transaction
        self.class.dispatch_to_main_connection(@main_connection_token, __method__)
      end

      def exec_restart_db_transaction
        self.class.dispatch_to_main_connection(@main_connection_token, __method__)
      end

      def reset_isolation_level
        self.class.dispatch_to_main_connection(@main_connection_token, __method__)
      end

      def last_inserted_id(result)
        result.rows.dig(0, 0)
      end

      def returning_column_values(result)
        result.rows.first || []
      end

      def method_missing(name, *args, **kwargs, &block)
        return super if block || name == :marshal_dump || name == :_dump

        self.class.dispatch_to_main_connection(@main_connection_token, name, args, kwargs)
      end

      def respond_to_missing?(name, include_private = false)
        return false if name == :marshal_dump || name == :_dump

        super
      end

      private
        def cast_result(result)
          result
        end

        def affected_rows(result)
          result.affected_rows
        end

        def ractor_query_binds(intent)
          intent.type_casted_binds
        rescue Ractor::Error, RuntimeError
          intent.binds
        end

        def perform_query(_raw_connection, intent)
          puts intent.processed_sql.inspect
          puts ractor_query_binds(intent).inspect
          request = QueryRequest.new(
            sql: intent.processed_sql,
            binds: ractor_query_binds(intent),
            name: intent.name || "SQL",
            prepare: intent.prepare,
            batch: intent.batch,
            allow_retry: intent.allow_retry,
            materialize_transactions: intent.materialize_transactions,
          )

          response = self.class.dispatch_query(@main_connection_token, request)
          result = response.to_result
          intent.notification_payload[:affected_rows] = result.affected_rows
          intent.notification_payload[:row_count] = result.length
          result
        end
    end
  end
end
