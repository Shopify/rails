# frozen_string_literal: true

# :markup: markdown

require "active_support/benchmarkable"

module AbstractController
  module Logger # :nodoc:
    extend ActiveSupport::Concern

    included do
      include ActiveSupport::Benchmarkable
    end

    class_methods do
      def logger
        config.logger
      end

      def logger=(logger)
        update_config_value(:logger, logger)
      end
    end

    def logger
      config.logger
    end

    def logger=(logger)
      self.class.logger = logger
    end
  end
end
