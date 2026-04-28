# frozen_string_literal: true

module Kernel
  module_function

  if defined?(Ractor)
    # Wraps +Ractor.make_shareable+ for a Proc literal. The block becomes a
    # shareable Proc suitable for use across Ractors (for example, as the
    # body of +define_method+).
    #
    #   handler = shareable_proc { |x| x.to_s }
    #
    # On Ruby implementations without Ractor support this returns a regular
    # Proc.
    def shareable_proc(&block)
      raise ArgumentError, "shareable_proc requires a block" unless block
      Ractor.make_shareable(block)
    end
  else
    def shareable_proc(&block) # :nodoc:
      raise ArgumentError, "shareable_proc requires a block" unless block
      block
    end
  end
end
