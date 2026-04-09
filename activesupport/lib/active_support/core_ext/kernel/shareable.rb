# frozen_string_literal: true

module Kernel
  # Creates a +Proc+ that is shareable across Ractors. The block must not
  # close over any unshareable values.
  #
  #   handler = shareable_proc { |x| x.to_s }
  #   Ractor.shareable?(handler) # => true
  #
  # This is a convenience wrapper around +Ractor.shareable_proc+. On Ruby
  # implementations without Ractor support it returns a regular +Proc+.
  if defined?(Ractor) && Ractor.respond_to?(:shareable_proc)
    def shareable_proc(&block)
      Ractor.shareable_proc(&block)
    end
  else
    def shareable_proc(&block)
      block
    end
  end

  module_function :shareable_proc
end
