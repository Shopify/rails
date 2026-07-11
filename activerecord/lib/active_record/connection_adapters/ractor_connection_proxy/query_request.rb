# frozen_string_literal: true

# :markup: markdown

module ActiveRecord
  module ConnectionAdapters
    class RactorConnectionProxy < AbstractAdapter # :nodoc:
      # Shareable request for the main-side `query` operation.
      class QueryRequest
        attr_reader :sql, :binds_payload, :name, :prepare, :batch, :allow_retry

        def initialize(sql:, binds_payload:, name:, prepare:, batch:, allow_retry:)
          @sql = RactorConnectionProxy.shareable_copy(sql)
          @binds_payload = binds_payload
          @name = RactorConnectionProxy.shareable_copy(name)
          @prepare = !!prepare
          @batch = !!batch
          @allow_retry = !!allow_retry
          ActiveSupport::Ractors.make_shareable(self, copy: false)
        end
      end
    end
  end
end
