# frozen_string_literal: true

module Arel # :nodoc: all
  module Collectors
    class Bind
      attr_accessor :retryable

      def initialize
        @binds = []
      end

      def <<(str)
        self
      end

      def add_bind(bind, &_)
        @binds << bind
        self
      end

      def add_binds(binds, proc_for_binds = nil, &_)
        @binds.concat proc_for_binds ? binds.map(&proc_for_binds) : binds
        self
      end

      def value
        @binds
      end
    end
  end
end
