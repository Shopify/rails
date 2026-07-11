# frozen_string_literal: true

# :markup: markdown

require "ractor/dispatch"

module ActiveRecord
  module ConnectionAdapters
    class RactorConnectionPool # :nodoc:
      Lease = Struct.new(:connection, :sticky)

      # Dispatches schema cache lookups to the schema cache of this pool's
      # main-Ractor counterpart (not to whatever pool `ActiveRecord::Base`
      # currently resolves to). The full BoundSchemaReflection interface is
      # defined up front so lookups never pay `method_missing` dispatch.
      class SchemaCacheProxy
        def initialize(pool)
          @pool = pool
        end

        BoundSchemaReflection.public_instance_methods(false).each do |method_name|
          class_eval(<<~RUBY, __FILE__, __LINE__ + 1)
            def #{method_name}(*args, **kwargs)
              @pool.dispatch_to_main_schema_cache(:#{method_name}, args, kwargs)
            end
          RUBY
        end
      end

      attr_reader :db_config, :role, :shard, :key

      def self.spec_for(pool) # :nodoc:
        pool_config = pool.pool_config
        ActiveSupport::Ractors.make_shareable({
          db_config: pool_config.db_config,
          connection_name: pool_config.connection_descriptor.name.to_s.freeze,
          role: pool_config.role,
          shard: pool_config.shard,
        }, copy: true)
      end

      def initialize(spec)
        @db_config = spec.fetch(:db_config)
        @connection_name = spec.fetch(:connection_name).to_s.freeze
        @role = spec.fetch(:role)
        @shard = spec.fetch(:shard)
        @key = [@connection_name, @role, @shard].freeze
        freeze
      end

      def inspect
        "#<#{self.class.name} env_name=#{db_config.env_name.inspect} name=#{db_config.name.inspect} role=#{role.inspect} shard=#{shard.inspect}>"
      end

      def connection_descriptor
        ConnectionHandler::ConnectionDescriptor.new(@connection_name, @connection_name == "ActiveRecord::Base")
      end

      def schema_reflection
        main_pool_value(:schema_reflection)
      end

      def schema_cache
        SchemaCacheProxy.new(self)
      end

      def dispatch_to_main_schema_cache(method_name, args, kwargs) # :nodoc:
        RactorConnectionProxy.dispatch_to_main_schema_cache(
          @connection_name, @role, @shard, method_name, args, kwargs, connection_pool: self
        )
      end

      def migration_context
        MigrationContext.new(migrations_paths, schema_migration, internal_metadata)
      end

      def migrations_paths
        db_config.migrations_paths || Migrator.migrations_paths
      end

      def schema_migration
        SchemaMigration.new(self)
      end

      def internal_metadata
        InternalMetadata.new(self)
      end

      def lease_connection
        lease = connection_lease
        lease.connection ||= checkout
        lease.sticky = true
        lease.connection
      end

      def permanent_lease?
        connection_lease.sticky.nil?
      end

      def active_connection?
        connection_lease.connection
      end
      alias :active_connection :active_connection?

      def release_connection(existing_lease = nil)
        lease = existing_lease || connection_lease
        if connection = lease.connection
          lease.connection = nil
          lease.sticky = nil
          checkin(connection)
          true
        else
          false
        end
      end

      def with_connection(prevent_permanent_checkout: false)
        lease = connection_lease
        sticky_was = lease.sticky
        lease.sticky = false if prevent_permanent_checkout

        if lease.connection
          begin
            yield lease.connection
          ensure
            lease.sticky = sticky_was if prevent_permanent_checkout && !sticky_was
          end
        else
          begin
            lease.connection = checkout
            yield lease.connection
          ensure
            lease.sticky = sticky_was if prevent_permanent_checkout && !sticky_was
            release_connection(lease) unless lease.sticky
          end
        end
      end

      def checkout(_checkout_timeout = nil)
        connection_token, profile = RactorConnectionProxy.checkout_connection(@connection_name, @role, @shard)
        RactorConnectionProxy.new(self, connection_token, profile, db_config.configuration_hash)
      end

      def checkin(connection)
        release_lease(connection)
        connection.expire if connection.in_use?
        connection.release_connection
      end

      # Backs `AbstractAdapter#throw_away!`.
      def remove(connection)
        release_lease(connection)
        connection.remove_connection
      end

      def connected?
        main_pool_value(:connected?)
      end

      def disconnect!
        release_connection
      end
      alias :flush! :disconnect!

      def disable_query_cache(dirties: true)
        cache = query_cache
        old_enabled, cache.enabled, old_dirties, cache.dirties = cache.enabled, false, cache.dirties, dirties
        begin
          yield
        ensure
          cache.enabled, cache.dirties = old_enabled, old_dirties
        end
      end

      def enable_query_cache
        cache = query_cache
        old_enabled, cache.enabled, old_dirties, cache.dirties = cache.enabled, true, cache.dirties, true
        begin
          yield
        ensure
          cache.enabled, cache.dirties = old_enabled, old_dirties
        end
      end

      def enable_query_cache!
        query_cache.enabled = true
        query_cache.dirties = true
      end

      def disable_query_cache!
        query_cache.enabled = false
        query_cache.dirties = true
      end

      def query_cache_enabled
        query_cache.enabled
      end

      def dirties_query_cache
        query_cache.dirties
      end

      def clear_query_cache
        query_cache.clear
      end

      def query_cache
        caches = (ActiveSupport::IsolatedExecutionState[:active_record_ractor_query_caches] ||= {})
        caches[key] ||= QueryCache::Store.new(Concurrent::AtomicFixnum.new, db_config.query_cache || QueryCache::DEFAULT_SIZE)
      end

      def pool_transaction_isolation_level
        ActiveSupport::IsolatedExecutionState[pool_transaction_isolation_level_key]
      end

      def pool_transaction_isolation_level=(isolation_level)
        ActiveSupport::IsolatedExecutionState[pool_transaction_isolation_level_key] = isolation_level
      end

      def with_pool_transaction_isolation_level(isolation_level, transaction_open)
        if !ActiveRecord.default_transaction_isolation_level.nil?
          begin
            if transaction_open && pool_transaction_isolation_level != ActiveRecord.default_transaction_isolation_level
              raise ActiveRecord::TransactionIsolationError, "cannot set default isolation level while transaction is open"
            end

            old_level = pool_transaction_isolation_level
            self.pool_transaction_isolation_level = isolation_level
            yield
          ensure
            self.pool_transaction_isolation_level = old_level
          end
        else
          yield
        end
      end

      def async_executor
      end

      def schedule_query(future_result)
        future_result.execute_or_skip
      end

      private
        def connection_lease
          leases = (ActiveSupport::IsolatedExecutionState[:active_record_ractor_connection_leases] ||= {})
          leases[key] ||= Lease.new(nil, nil)
        end

        def release_lease(connection)
          lease = connection_lease
          if lease.connection.equal?(connection)
            lease.connection = nil
            lease.sticky = nil
          end
        end

        def pool_transaction_isolation_level_key
          "activerecord_pool_transaction_isolation_level_#{@db_config.name}"
        end

        def main_pool_value(method_name)
          RactorConnectionProxy.dispatch_to_main_pool(@connection_name, @role, @shard, method_name, [], {}, connection_pool: self)
        end

        def method_missing(name, *args, **kwargs, &block)
          return super if block

          RactorConnectionProxy.dispatch_to_main_pool(@connection_name, @role, @shard, name, args, kwargs, connection_pool: self)
        end

        def respond_to_missing?(_name, _include_private = false)
          true
        end
    end
  end
end
