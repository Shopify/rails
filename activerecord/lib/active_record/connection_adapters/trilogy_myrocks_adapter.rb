# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    class TrilogyMyRocksAdapter < TrilogyAdapter
      ADAPTER_NAME = "TrilogyMyRocks"

      def supports_savepoints?
        false
      end
    end
  end
end
