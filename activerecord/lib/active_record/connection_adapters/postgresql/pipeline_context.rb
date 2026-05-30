# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module PostgreSQL
      # Manages PostgreSQL's pipeline mode for batching multiple queries
      # in a single network round-trip.
      #
      # Pipeline mode allows sending multiple queries without waiting for
      # results, then collecting all results together. This reduces latency
      # for sequences of queries that don't depend on each other's results.
      module PipelineContext # :nodoc:
        # When true, consume PGRES_PIPELINE_SYNC results explicitly.
        # When false, skip them during result collection (using get_result loop).
        # True is needed for concurrent result collection; false is simpler for now.
        # SyncIntent markers are always recorded to track sync boundaries.
        TRACK_SYNCS = false

        # Marker for sync points in the pipeline.
        class SyncIntent # :nodoc:
          attr_accessor :raw_result

          def raw_result_available?
            !@raw_result.nil?
          end
        end

        def pipeline_active?
          @lock.synchronize do
            connected? && @raw_connection.pipeline_status != PG::PQ_PIPELINE_OFF
          end
        end

        def pipeline_pending?
          @lock.synchronize do
            @pending_intents ||= []
            @pending_intents.any?
          end
        end

        def enter_pipeline_mode
          @lock.synchronize do
            return if pipeline_active?
            raise "Cannot enter pipeline mode: pipelining is locked" if @pipelining_locked

            unless connected?
              raise ActiveRecord::ConnectionFailed, "Connection is not usable while entering pipeline mode"
            end

            @raw_connection.enter_pipeline_mode
          end
        end

        def pipeline_sync
          @lock.synchronize do
            return unless pipeline_active?

            @pending_intents ||= []

            # Probe the connection before recording a sync marker. Flush
            # sends any buffered query data, then consume_input reads from
            # the socket - either will raise on a dead connection while we
            # still know no sync has been sent. (Flush alone isn't enough:
            # libpq may have eagerly sent query data during send_query_params,
            # leaving the write buffer empty. consume_input always has
            # something to check on the read side.)
            #
            # If these probes succeed, we record the SyncIntent - the server
            # may have received the queries. Then pipeline_sync sends the
            # actual sync message. If *that* fails, the marker stays:
            # conservatively assuming the sync might have reached the wire.
            @raw_connection.flush
            @raw_connection.consume_input
            @pending_intents << SyncIntent.new
            @raw_connection.pipeline_sync
          rescue PG::Error
            if error = consume_available_fatal_result
              raise error
            else
              raise
            end
          end
        end

        def exit_pipeline_mode
          @lock.synchronize do
            return unless pipeline_active?
            raise "Cannot exit pipeline mode: pipelining is locked" if @pipelining_locked

            begin
              flush_pipeline if connected?
            ensure
              abandon_pipelined_intents

              if connected?
                begin
                  # Drain any unconsumed results (e.g. from replay or
                  # a failed flush) so we can cleanly exit pipeline mode.
                  @raw_connection.pipeline_sync
                  loop do
                    result = @raw_connection.get_result
                    break unless result
                  end
                rescue PG::Error
                  # Connection dead, can't discard
                end
              end
            end

            if connected?
              begin
                @raw_connection.exit_pipeline_mode
              rescue PG::Error
                # Pipeline still dirty (e.g. unconsumed results from a
                # failed flush). Close the connection so it gets
                # re-established on next use.
                @raw_connection.close rescue nil
              end
            end
          end
        end

        # Add a query intent to the pipeline.
        # The intent's raw_result will be populated when the pipeline is flushed.
        def pipeline_add_query(intent)
          @lock.synchronize do
            raise "Pipeline mode not active" unless pipeline_active?

            @pending_intents ||= []

            # Send the query to the pipeline.
            # Always use send_query_params in pipeline mode (even with empty binds array).
            @raw_connection.send_query_params(
              intent.processed_sql,
              intent.type_casted_binds || []
            )

            # Only add to pending list after successful send to avoid misalignment
            # if send_query_params raises an exception.
            @pending_intents << intent
          end

          intent
        end

        # Flush pending queries and collect results.
        #
        # Connection errors during sync/drain are handled with transparent
        # replay when all outstanding intents are eligible, otherwise intents
        # are abandoned with appropriate terminal states.
        def flush_pipeline
          @lock.synchronize do
            return unless pipeline_active?
            return unless pipeline_pending?

            # Track which intent was at the head of the last replay
            # attempt. If we come back around and the same intent is
            # still leading, we're not making progress - give up.
            # If the head has advanced (some intents succeeded), that's
            # genuine progress and worth another attempt.
            last_replayed_head = nil

            loop do
              begin
                pipeline_sync
                consumed = consume_pipeline
              rescue PG::Error => error
                translated = translate_exception_with_cause(error, nil, nil)

                # A FATAL error means the server explicitly told us it's
                # terminating the connection. Everything still in
                # @pending_intents is definitively not-executed, so all
                # are safe to replay regardless of allow_retry.
                server_fatal = error.respond_to?(:result) &&
                  connection_terminating_severity?(error.result)

                replayable = retryable_connection_error?(translated) &&
                  reconnect_can_restore_state? &&
                  if server_fatal
                    abandon_pipelined_intents(translated, allow_recovery: true, all_unsynced: true, last_replayed_head: last_replayed_head)
                  else
                    abandon_pipelined_intents(translated, allow_recovery: true, last_replayed_head: last_replayed_head)
                  end

                if replayable
                  last_replayed_head = replayable.first
                  reconnect!(restore_transactions: true)
                  enter_pipeline_mode
                  replayable.each { |intent| pipeline_add_query(intent) }
                  next
                end

                # abandon_pipelined_intents already delivered terminal
                # states if it was called (retryable error but recovery
                # blocked). For non-retryable errors, abandon now.
                abandon_pipelined_intents(translated)
                return
              end

              # Check if consume_pipeline encountered a connection error
              # in a pipeline result (e.g., AdminShutdown). Only intents
              # that failed or were not run need replay; successfully
              # resolved intents keep their results.
              needs_replay = consumed&.select { |intent| intent.error || intent.not_run_reason }
              if needs_replay&.any? { |intent| intent.error && retryable_connection_error?(intent.error) }
                if reconnect_can_restore_state? && needs_replay.all?(&:allow_retry) && needs_replay.first != last_replayed_head
                  last_replayed_head = needs_replay.first
                  needs_replay.each(&:reset_for_retry)
                  reconnect!(restore_transactions: true)
                  enter_pipeline_mode
                  needs_replay.each { |intent| pipeline_add_query(intent) }
                  next
                end
              end

              return
            end
          end
        ensure
          maybe_deferred_release
        end

        def consume_pipeline
          @lock.synchronize do
            @pending_intents ||= []
            return if @pending_intents.empty?

            consumed = []
            buffered = []

            while intent = @pending_intents[buffered.length]
              if intent.is_a?(SyncIntent)
                sync_result = @raw_connection.get_result
                return discard_buffered_results(buffered, consumed) unless sync_result

                sync_result.check

                unless sync_result.result_status == PG::PGRES_PIPELINE_SYNC
                  raise "BUG: expected pipeline sync result, got #{sync_result.result_status}"
                end

                finalized_count = buffered.length + 1
                @pending_intents.shift(finalized_count)

                intent.raw_result = sync_result if TRACK_SYNCS
                sync_result.clear unless TRACK_SYNCS

                deliver_buffered_intents(buffered, consumed)
                buffered = []
                next
              end

              raw_result = get_result(@raw_connection)
              return discard_buffered_results(buffered, consumed) unless raw_result

              if raw_result.result_status == PG::PGRES_PIPELINE_ABORTED
                buffered << [:not_run, intent, :server_aborted, take_notice_receiver_warnings]
                next
              end

              begin
                raw_result.check
              rescue => error
                translated = translate_exception_with_cause(error, intent.processed_sql, intent.binds)
                if retryable_connection_error?(translated)
                  discard_buffered_results(buffered)
                  raise error
                end

                buffered << [:failure, intent, translated, take_notice_receiver_warnings]
                next
              end

              buffered << [:result, intent, raw_result, take_notice_receiver_warnings]
            end

            consumed
          end
        end

        private
          def consume_available_fatal_result
            while !@raw_connection.is_busy && (result = @raw_connection.get_result)
              if result.result_status == PG::PGRES_FATAL_ERROR &&
                  connection_terminating_severity?(result)
                result.check
              end

              result.clear
            end

            consume_notice_receiver_fatal_error
          rescue PG::Error => error
            error if error.respond_to?(:result) && error.result
          end

          def discard_buffered_results(buffered, return_value = nil)
            buffered.each do |kind, _intent, value, _warnings|
              value.clear if kind == :result
            end
            buffered.clear
            return_value
          end

          def deliver_buffered_intents(buffered, consumed)
            buffered.each do |kind, intent, value, warnings|
              case kind
              when :result
                if intent.notification_payload && value
                  intent.notification_payload[:affected_rows] = value.cmd_tuples
                  intent.notification_payload[:row_count] = value.ntuples
                end
                intent.deliver_result(value, warnings: warnings)
              when :failure
                intent.deliver_failure(value, warnings: warnings)
              when :not_run
                intent.deliver_not_run(reason: value, warnings: warnings)
              end

              consumed << intent
            end
          ensure
            buffered.clear
          end

          def take_notice_receiver_warnings
            @notice_receiver_sql_warnings.tap do
              @notice_receiver_sql_warnings = []
            end
          end

          # Classify and deliver terminal states to all pending intents after
          # a connection failure, based on sync boundaries.
          #
          # When +allow_recovery+ is true and every intent is eligible for
          # replay (synced intents must have allow_retry; unsynced are always
          # eligible), returns the intents instead of marking them so the
          # caller can reconnect and replay. Returns nil otherwise.
          #
          # +last_replayed_head+ gates progress: if the first intent in the
          # replay list is the same as the last attempt, we're not making
          # progress and fall through to deliver terminal states instead.
          def abandon_pipelined_intents(connection_error = nil, allow_recovery: false, all_unsynced: false, last_replayed_head: nil)
            intents = @pending_intents
            @pending_intents = []

            return unless intents&.any?

            if all_unsynced
              # Server sent FATAL - the connection is dying. The first
              # pending intent (which received the FATAL) may have been
              # partially executed, so it respects allow_retry like a
              # synced intent. Everything after it is definitively
              # not-run.
              first_real = intents.index { |i| !i.is_a?(SyncIntent) }
              synced = first_real ? [intents[first_real]] : []
              unsynced = first_real ? intents[(first_real + 1)..].reject { |i| i.is_a?(SyncIntent) } : []
            else
              # Partition intents by sync state: intents before a SyncIntent
              # were synced (server may have executed), intents after the last
              # SyncIntent were never synced (definitely not executed).
              synced = []
              unsynced = []

              intents.each do |intent|
                if intent.is_a?(SyncIntent)
                  synced.concat(unsynced)
                  unsynced = []
                else
                  unsynced << intent
                end
              end
            end

            if allow_recovery && synced.all? { |intent| intent.allow_retry }
              all = synced + unsynced
              if all.first != last_replayed_head
                all.each(&:reset_for_retry)
                return all
              end
            end

            error = connection_error || ActiveRecord::ConnectionFailed.new("Connection lost during pipeline execution")
            synced.each { |intent| intent.deliver_failure(error) }
            unsynced.each { |intent| intent.deliver_not_run(reason: :unsynced) }

            nil
          end
      end
    end
  end
end
