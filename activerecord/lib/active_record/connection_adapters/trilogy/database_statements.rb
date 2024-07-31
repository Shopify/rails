# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Trilogy
      module DatabaseStatements
        private
          def perform_query(raw_connection, sql, binds, type_casted_binds, prepare:, notification_payload:)
            # Make sure we carry over any changes to ActiveRecord.default_timezone that have been
            # made since we established the connection
            if default_timezone == :local
              raw_connection.query_flags |= ::Trilogy::QUERY_FLAGS_LOCAL_TIMEZONE
            else
              raw_connection.query_flags &= ~::Trilogy::QUERY_FLAGS_LOCAL_TIMEZONE
            end

            result = raw_connection.query(sql)
            while raw_connection.more_results_exist?
              raw_connection.next_result
            end
            verified!
            handle_warnings(sql)
            notification_payload[:row_count] = result.count
            result
          end

          def cast_result(result)
            if result.fields.empty?
              ActiveRecord::Result.empty
            else
              ActiveRecord::Result.new(result.fields, result.rows)
            end
          end

          def affected_rows(result)
            result.affected_rows
          end

          def last_inserted_id(raw_result)
            raw_result.last_insert_id
          end

          def execute_batch(statements, name = nil)
            combine_multi_statements(statements).each do |statement|
              with_raw_connection do |conn|
                raw_execute(statement, name)
              end
            end
          end

          def multi_statements_enabled?
            !!@config[:multi_statement]
          end

          def with_multi_statements
            if multi_statements_enabled?
              return yield
            end

            with_raw_connection do |conn|
              conn.set_server_option(::Trilogy::SET_SERVER_MULTI_STATEMENTS_ON)

              yield
            ensure
              conn.set_server_option(::Trilogy::SET_SERVER_MULTI_STATEMENTS_OFF) if active?
            end
          end
      end
    end
  end
end
