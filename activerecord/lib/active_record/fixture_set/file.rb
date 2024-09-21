# frozen_string_literal: true

require "active_support/configuration_file"

module ActiveRecord
  class FixtureSet
    class File # :nodoc:
      include Enumerable

      ##
      # Open a fixture file named +file+.  When called with a block, the block
      # is called with the filehandle and the filehandle is automatically closed
      # when the block finishes.
      def self.open(file, fixture_read_cache={})
        x = new(file, fixture_read_cache)
        block_given? ? yield(x) : x
      end

      def initialize(file, fixture_read_cache = {})
        @file = file
        @fixture_read_cache = fixture_read_cache
      end

      def each(&block)
        rows.each(&block)
      end

      def current_version
        @current_version ||= ActiveRecord::Migrator.current_version
      end

      def model_class
        config_row["model_class"]
      end

      def ignored_fixtures
        config_row["ignore"]
      end

      private
        def rows
          @rows ||= raw_rows.reject { |fixture_name, _| fixture_name == "_fixture" }
        end

        def config_row
          @config_row ||= begin
            row = raw_rows.find { |fixture_name, _| fixture_name == "_fixture" }
            if row
              validate_config_row(row.last)
            else
              { 'model_class': nil, 'ignore': nil }
            end
          end
        end

        def raw_rows
          if @file.end_with?(".yml.erb") || @fixture_read_cache.is_a?(Hash)
            @raw_rows ||= begin
              data = ActiveSupport::ConfigurationFile.parse(@file, context:
                ActiveRecord::FixtureSet::RenderContext.create_subclass.new.get_binding)
              data ? validate(data).to_a : []
            rescue RuntimeError => error
              raise Fixture::FormatError, error.message
            end
          else
            cache_key = "#{@file}:#{@current_version}"
            cached_read = @fixture_read_cache.read(cache_key)
            # puts(cached_read ? "Hit: #{cache_key}" : "Miss: #{cache_key}")
            return cached_read if cached_read

            @raw_rows ||= begin
              data = ActiveSupport::ConfigurationFile.parse(@file, context:
                ActiveRecord::FixtureSet::RenderContext.create_subclass.new.get_binding)
              data ? validate(data).to_a : []
            rescue RuntimeError => error
              raise Fixture::FormatError, error.message
            end

            @fixture_read_cache.write(cache_key, @raw_rows)
            @raw_rows
          end
        end

        def validate_config_row(data)
          unless Hash === data
            raise Fixture::FormatError, "Invalid `_fixture` section: `_fixture` must be a hash: #{@file}"
          end

          begin
            data.assert_valid_keys("model_class", "ignore")
          rescue ArgumentError => error
            raise Fixture::FormatError, "Invalid `_fixture` section: #{error.message}: #{@file}"
          end

          data
        end

        # Validate our unmarshalled data.
        def validate(data)
          unless Hash === data || YAML::Omap === data
            raise Fixture::FormatError, "fixture is not a hash: #{@file}"
          end

          invalid = data.reject { |_, row| Hash === row }
          if invalid.any?
            raise Fixture::FormatError, "fixture key is not a hash: #{@file}, keys: #{invalid.keys.inspect}"
          end
          data
        end
    end
  end
end
