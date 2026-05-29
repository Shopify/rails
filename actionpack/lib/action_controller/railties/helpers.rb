# frozen_string_literal: true

# :markup: markdown

require "active_support/core_ext/kernel/ractor_shareability"

module ActionController
  module Railties
    module Helpers
      def inherited(klass)
        super
        return unless klass.respond_to?(:helpers_path=)

        if namespace = klass.module_parents.detect { |m| m.respond_to?(:railtie_helpers_paths) }
          paths = namespace.railtie_helpers_paths
        else
          paths = ActionController::Helpers.helpers_path
        end

        klass.helpers_path = ractor_make_shareable(paths.dup)

        if klass.superclass == ActionController::Base && ActionController::Base.include_all_helpers
          klass.helper :all
        end
      end
    end
  end
end
