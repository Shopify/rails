# frozen_string_literal: true

module ActionView
  module CacheExpiry # :nodoc: all
    cattr_accessor :view_reloader, instance_accessor: false

    class ViewReloader # :nodoc:
      def initialize(watcher:, &block)
        @mutex = Mutex.new
        @watcher_class = watcher
        @watched_dirs = nil
        @watcher = nil
        @previous_change = false
        @watching = false

        ActionView::PathRegistry.file_system_resolver_hooks << method(:rebuild_watcher)
      end

      def updated?
        build_watcher if @watching && !@watcher
        @previous_change || @watcher&.updated?
      end

      def execute
        return unless @watcher

        watcher = nil
        @mutex.synchronize do
          @previous_change = false
          watcher = @watcher
        end
        watcher.execute
      end

      def build_watcher
        @mutex.synchronize do
          old_watcher = @watcher

          if @watched_dirs != dirs_to_watch
            @watched_dirs = dirs_to_watch
            new_watcher = @watcher_class.new([], @watched_dirs) do
              reload!
            end
            @watcher = new_watcher
            @watching = true

            # We must check the old watcher after initializing the new one to
            # ensure we don't miss any events
            @previous_change ||= old_watcher&.updated?
          end
        end
      end

      private
        def reload!
          ActionView::LookupContext::DetailsKey.clear
        end

        def rebuild_watcher
          return unless @watcher
          build_watcher
        end

        def dirs_to_watch
          all_view_paths.uniq.sort
        end

        def all_view_paths
          ActionView::PathRegistry.all_file_system_resolvers.map(&:path)
        end
    end
  end
end
