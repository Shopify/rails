# frozen_string_literal: true

require "singleton"

module ActiveRecord
  module ConnectionAdapters
    class RactorConnectionHandler # :nodoc:
      include Singleton

      @pool_specs = {}.freeze

      class << self
        attr_reader :pool_specs

        def capture_main_pool_specs!
          specs = {}
          ActiveRecord::Base.connection_handler.connection_pool_list.each do |pool|
            spec = RactorConnectionPool.spec_for(pool)
            specs[[spec.fetch(:connection_name), spec.fetch(:role), spec.fetch(:shard)].freeze] = spec
          end
          @pool_specs = Ractor.make_shareable(specs)
        end
      end

      def connection_pool_list(role = nil)
        if !ActiveSupport::Ractors.main? && self.class.pool_specs.any?
          specs = self.class.pool_specs.values
          specs = specs.select { |spec| spec.fetch(:role) == role } if role
          specs.map { |pool_spec| RactorConnectionPool.new(pool_spec) }
        else
          RactorConnectionProxy.main_pool_specs(role).map { |pool_spec| RactorConnectionPool.new(pool_spec) }
        end
      end
      alias :connection_pools :connection_pool_list

      def each_connection_pool(role = nil, &block)
        return enum_for(__method__, role) unless block_given?

        connection_pool_list(role).each(&block)
      end

      def retrieve_connection(connection_name, role: ActiveRecord::Base.current_role, shard: ActiveRecord::Base.current_shard)
        retrieve_connection_pool(connection_name, role: role, shard: shard, strict: true).lease_connection
      end

      def retrieve_connection_pool(connection_name, role: ActiveRecord::Base.current_role, shard: ActiveRecord::Base.current_shard, strict: false)
        connection_name = connection_name.to_s
        if !ActiveSupport::Ractors.main? && self.class.pool_specs.any?
          pool_spec = self.class.pool_specs.fetch([connection_name, role, shard], nil)
          if pool_spec
            RactorConnectionPool.new(pool_spec)
          elsif strict
            raise ConnectionNotDefined, "No connection pool for #{connection_name} found for the #{role} role and #{shard} shard."
          end
        else
          pool_spec = RactorConnectionProxy.main_pool_spec(connection_name, role, shard, strict)
          pool_spec && RactorConnectionPool.new(pool_spec)
        end
      end

      def connected?(connection_name, role: ActiveRecord::Base.current_role, shard: ActiveRecord::Base.current_shard)
        pool = retrieve_connection_pool(connection_name, role: role, shard: shard)
        pool && pool.connected?
      end

      def active_connections?(role = nil)
        each_connection_pool(role).any?(&:active_connection?)
      end

      def clear_active_connections!(role = nil)
        each_connection_pool(role).each do |pool|
          pool.release_connection
          pool.disable_query_cache!
        end
      end

      def clear_reloadable_connections!(role = nil)
        clear_active_connections!(role)
      end

      def clear_all_connections!(role = nil)
        each_connection_pool(role).each(&:disconnect!)
      end

      def flush_idle_connections!(role = nil)
        each_connection_pool(role).each(&:flush!)
      end

      def establish_connection(config, owner_name: Base, role: Base.current_role, shard: Base.current_shard, clobber: false)
        owner_name = owner_name.name if owner_name.respond_to?(:name)
        owner_name = owner_name.to_s
        db_config = config

        pool_spec = Ractor::Dispatch.main.run do
          pool = ActiveRecord::Base.connection_handler.establish_connection(
            db_config,
            owner_name: owner_name,
            role: role,
            shard: shard,
            clobber: clobber,
          )
          RactorConnectionPool.spec_for(pool)
        end

        RactorConnectionPool.new(pool_spec)
      end

      instance.freeze
    end
  end
end
