# frozen_string_literal: true

module ActionView
  module Helpers
    module Tags # :nodoc:
      class TimeSelect < DateSelect # :nodoc:
        class << self
          def select_type
            "time"
          end
        end
      end
    end
  end
end
