# frozen_string_literal: true

require "active_record/connection_adapters/sqlite3_adapter"

module ActiveRecord
  module ConnectionAdapters
    # = Active Record Ractor-safe \SQLite3 Adapter
    #
    # A database adapter that dispatches all database I/O through
    # +Ractor::Dispatch+ to the main Ractor, where it is executed
    # against the +delegate_adapter+'s connection pool.
    #
    # This adapter never touches SQLite3 directly. It serializes
    # query intent into a Ractor-shareable +QueryRequest+, sends it
    # to the main Ractor via +Ractor::Dispatch+, and the main Ractor
    # checks out a connection from the delegate adapter's pool to
    # execute the query. The result comes back as a Ractor-shareable
    # +QueryResponse+.
    #
    # == Configuration
    #
    # Use <tt>adapter: ractor_sqlite3</tt> in +database.yml+:
    #
    #   production:
    #     primary:
    #       adapter: ractor_sqlite3
    #       delegate_adapter: primary_sqlite
    #     primary_sqlite:
    #       adapter: sqlite3
    #       database: storage/production.sqlite3
    #
    # The +delegate_adapter+ key names another database configuration
    # whose connection pool will execute the actual SQL on the main
    # Ractor.
    class RactorSQLite3Adapter < SQLite3Adapter
      ADAPTER_NAME = "RactorSQLite3"

      # Skip +SQLite3Adapter#initialize+ which validates the +database+
      # config key and sets up +@connection_parameters+ for a real
      # SQLite3 connection. This adapter has no local database file;
      # it delegates all I/O through +DispatchConfig+.
      def initialize(config_or_deprecated_connection, *args)
        # Jump straight to AbstractAdapter#initialize, bypassing
        # SQLite3Adapter's database-path checks.
        AbstractAdapter.instance_method(:initialize)
          .bind_call(self, config_or_deprecated_connection, *args)

        @connection_parameters = @config
      end

      # -----------------------------------------------------------
      # Connection lifecycle overrides
      #
      # The ractor adapter holds a +DispatchConfig+ as its
      # +@raw_connection+ instead of a +SQLite3::Database+. These
      # overrides keep the pool happy without touching SQLite3.
      # -----------------------------------------------------------

      def connected?
        !@raw_connection.nil?
      end

      def active?
        connected?
      end

      def disconnect!
        super
        @raw_connection = nil
      end

      def database_exists?
        true
      end

      # == Ractor-shareable Query Request
      #
      # A frozen, Ractor-shareable value object that captures everything
      # needed to execute a query: the SQL string, bind parameters, and
      # execution flags. Created in any Ractor and sent to the main
      # Ractor for execution.
      class QueryRequest
        attr_reader :sql, :binds, :name, :prepare, :batch,
                    :allow_retry, :materialize_transactions

        def initialize(sql:, binds:, name:, prepare:, batch:,
                       allow_retry:, materialize_transactions:)
          @sql   = sql.frozen? ? sql : sql.dup.freeze
          @binds = binds.map { |v| v.frozen? ? v : v.dup.freeze }.freeze
          @name  = name.frozen? ? name : name.dup.freeze
          @prepare = prepare
          @batch   = batch
          @allow_retry = allow_retry
          @materialize_transactions = materialize_transactions
          Ractor.make_shareable(self)
        end
      end

      # == Ractor-shareable Query Response
      #
      # A frozen, Ractor-shareable value object wrapping an
      # +ActiveRecord::Result+. The columns, rows, and column_types
      # are deep-frozen so the response can travel back from the main
      # Ractor to any worker Ractor.
      class QueryResponse
        attr_reader :columns, :rows, :column_types, :affected_rows

        def initialize(result)
          @columns       = result.columns.map(&:freeze).freeze
          @rows          = result.rows.map { |r| r.map { |v| v.frozen? ? v : v.dup.freeze }.freeze }.freeze
          @column_types  = result.column_types.transform_values { |v| v.frozen? ? v : v.dup.freeze }.freeze
          @affected_rows = result.affected_rows
          freeze
        end

        # Reconstruct an +ActiveRecord::Result+ from the frozen data.
        def to_result
          ActiveRecord::Result.new(@columns, @rows, @column_types, affected_rows: @affected_rows)
        end
      end

      class << self
        # Creates a +DispatchConfig+ instead of a raw
        # +SQLite3::Database+ handle. The +delegate_adapter+ key names
        # the database configuration whose connection pool will execute
        # actual SQL on the main Ractor via +Ractor::Dispatch+.
        def new_client(config)
          DispatchConfig.new(config)
        end
      end

      # == Dispatch Config
      #
      # A frozen, Ractor-shareable object returned by +.new_client+ in
      # place of a raw +SQLite3::Database+ handle. Resolves the delegate
      # adapter's connection pool at boot time and dispatches
      # +QueryRequest+ objects to the main Ractor for execution against
      # that pool.
      class DispatchConfig
        def initialize(config)
          @delegate_adapter_name = config.fetch(:delegate_adapter) {
            raise ArgumentError,
              "ractor_sqlite3 adapter requires a `delegate_adapter` key " \
              "in database.yml pointing to the database config to delegate to"
          }.to_s.freeze

          freeze
        end

        # Quack like +SQLite3::Database+ just enough for guards
        # against unexpected calls from the base class.
        def closed?
          false
        end

        # Execute a +QueryRequest+ on the main Ractor and return a
        # +QueryResponse+.
        #
        # Dispatches via +Ractor::Dispatch+ so that the sqlite3 C
        # extension (which is not Ractor-safe) always executes on
        # the main Ractor. The delegate adapter's connection pool
        # handles the actual database I/O.
        def execute(request)
          delegate_name = @delegate_adapter_name

          Ractor::Dispatch.main.run do
            db_config = ActiveRecord::Base.configurations
              .configs_for(env_name: Rails.env, name: delegate_name)

            pool = ActiveRecord::Base.connection_handler
              .establish_connection(db_config)

            pool.with_connection do |conn|
              result = if request.batch
                conn.execute(request.sql, request.name)
              elsif request.prepare
                conn.exec_query(request.sql, request.name, request.binds, prepare: true)
              else
                conn.exec_query(request.sql, request.name, request.binds)
              end

              QueryResponse.new(result)
            end
          end
        end
      end

      private
        # Build a +QueryRequest+ from the +QueryIntent+ and dispatch it
        # to the main Ractor for execution against the delegate adapter's
        # connection pool.
        def perform_query(raw_connection, intent)
          request = QueryRequest.new(
            sql:   intent.processed_sql,
            binds: intent.type_casted_binds,
            name:  intent.name || "SQL",
            prepare: intent.prepare,
            batch:   intent.batch,
            allow_retry: intent.allow_retry,
            materialize_transactions: intent.materialize_transactions
          )

          response = raw_connection.execute(request)

          result = response.to_result
          intent.notification_payload[:affected_rows] = result.affected_rows
          intent.notification_payload[:row_count] = result.length
          result
        end

        # Create a +DispatchConfig+ as the raw connection.
        def connect
          @raw_connection = self.class.new_client(@connection_parameters)
        end

        # Reconnect by replacing the +DispatchConfig+.
        def reconnect
          connect
        end

        # No SQLite3 pragmas or timeouts to configure.
        def configure_connection
        end
    end
  end
end
