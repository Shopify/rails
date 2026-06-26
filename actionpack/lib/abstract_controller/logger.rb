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
        if defined?(Rails) && !ActiveSupport::Ractors.main?
          Rails.logger
        else
          config.logger
        end
      end

      def logger=(logger)
        config.logger = logger
      end
    end

    def logger
      if defined?(Rails) && !ActiveSupport::Ractors.main?
        Rails.logger
      else
        config.logger
      end
    end

    def logger=(logger)
      config.logger = logger
    end
  end
end
