# frozen_string_literal: true

module Rails
  class Autoloaders # :nodoc:
    require_relative "autoloaders/inflector"

    include Enumerable

    attr_reader :main, :once

    def initialize
      # This `require` delays loading the library on purpose.
      #
      # In Rails 7.0.0, railties/lib/rails.rb loaded Zeitwerk as a side-effect,
      # but a couple of edge cases related to Bundler and Bootsnap showed up.
      # They had to do with order of decoration of `Kernel#require`, something
      # the three of them do.
      #
      # Delaying this `require` up to this point is a convenient trade-off.
      require "zeitwerk"
      self.class.zeitwerk_loader_freeze

      @main = Zeitwerk::Loader.new
      @main.tag = "rails.main"
      @main.inflector = Inflector

      @once = Zeitwerk::Loader.new
      @once.tag = "rails.once"
      @once.inflector = Inflector
    end

    def self.zeitwerk_loader_freeze
      if [::Zeitwerk::Loader, ::Zeitwerk::Loader::Config, ::Zeitwerk::Cref::Map]
        .any? { it.instance_methods(false).include?(:freeze) }
        raise "remove me" # FIXME
      else
        ::Zeitwerk::Loader.class_eval do
          def freeze
            raise "can't freeze a loader that hasn't been eager loaded" unless @eager_loaded

            @autoloads.freeze
            @inceptions.freeze
            @autoloaded_dirs.freeze
            @to_unload.freeze
            @namespace_dirs.freeze
            @shadowed_files.freeze
            @setup.freeze
            @eager_loaded.freeze

            @mutex = nil
            @dirs_autoload_monitor = nil

            super
          end
        end

        ::Zeitwerk::Loader::Config.class_eval do
          def freeze
            @inflector.freeze
            @logger.freeze
            @tag.freeze
            @initialized_at.freeze
            @roots.freeze
            @ignored_glob_patterns.freeze
            @ignored_paths.freeze
            @collapse_glob_patterns.freeze
            @collapse_dirs.freeze
            @eager_load_exclusions.freeze
            @reloading_enabled.freeze
            @on_setup_callbacks.freeze
            @on_load_callbacks.freeze
            @on_unload_callbacks.freeze

            super
          end
        end

        ::Zeitwerk::Cref::Map.class_eval do
          def freeze
            @mutex = nil

            super
          end
        end
      end
    end

    def freeze
      @main.freeze
      @once.freeze
      super
    end

    def each
      yield main
      yield once
    end

    def logger=(logger)
      each { |loader| loader.logger = logger }
    end

    def log!
      each(&:log!)
    end

    def zeitwerk_enabled?
      true
    end
  end
end
