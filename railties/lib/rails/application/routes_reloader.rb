# frozen_string_literal: true

require "active_support/core_ext/object/shareable"

module Rails
  class Application
    class RoutesReloader
      include ActiveSupport::Callbacks

      NOOP_AFTER_LOAD_PATHS = (-> { }).make_shareable!
      private_constant :NOOP_AFTER_LOAD_PATHS

      attr_reader :route_sets, :paths, :external_routes, :loaded
      attr_accessor :eager_load
      attr_writer :run_after_load_paths, :loaded # :nodoc:
      delegate :execute_if_updated, :updated?, to: :updater

      def initialize(file_watcher: ActiveSupport::FileUpdateChecker)
        @paths      = []
        @route_sets = []
        @external_routes = []
        @eager_load = false
        @loaded = false
        @file_watcher = file_watcher
      end

      # Drop the file watcher and its memoized updater before freezing.
      # The updater block captures `self` to call `reload!`, which makes it
      # non-shareable. A frozen application doesn't reload routes, so the
      # watcher isn't needed after boot.
      def freeze
        @updater = nil
        @file_watcher = nil
        super
      end

      def reload!
        clear!
        load_paths
        finalize!
        route_sets.each(&:eager_load!) if eager_load
      ensure
        revert
      end

      def execute
        @loaded = true
        updater.execute
      end

      def execute_unless_loaded
        unless @loaded
          execute
          ActiveSupport.run_load_hooks(:after_routes_loaded, Rails.application)
          true
        end
      end

    private
      def updater
        @updater ||= begin
          dirs = @external_routes.each_with_object({}) do |dir, hash|
            hash[dir.to_s] = %w(rb)
          end

          @file_watcher.new(paths, dirs) { reload! }
        end
      end

      def clear!
        route_sets.each do |routes|
          routes.disable_clear_and_finalize = true
          routes.clear!
        end
      end

      def load_paths
        paths.each { |path| load(path) }
        run_after_load_paths.call
      end

      def run_after_load_paths
        @run_after_load_paths || NOOP_AFTER_LOAD_PATHS
      end

      def finalize!
        route_sets.each(&:finalize!)
      end

      def revert
        route_sets.each do |routes|
          routes.disable_clear_and_finalize = false
        end
      end
    end
  end
end
