# frozen_string_literal: true

module ActionView
  module Helpers
    module Tags # :nodoc:
      class DatetimeSelect < DateSelect # :nodoc:
        class << self
          def select_type
            "datetime"
          end
        end
      end
    end
  end
end
