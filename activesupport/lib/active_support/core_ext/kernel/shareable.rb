# frozen_string_literal: true

module Kernel
  module_function

  if defined?(Ractor) && Ractor.respond_to?(:shareable_proc)
    # Wraps +Ractor.shareable_proc+ for a Proc literal. The block becomes a
    # shareable Proc suitable for use across Ractors (for example, as the
    # body of +define_method+).
    #
    # Unlike +Ractor.make_shareable+, this primitive detaches the proc from
    # its enclosing scope, so it can be used inside an instance method even
    # when the receiver itself is not shareable. The proc must, of course,
    # not capture any non-shareable locals.
    #
    #   handler = shareable_proc { |x| x.to_s }
    #
    # On Ruby implementations without Ractor support (or without
    # +Ractor.shareable_proc+) this returns a regular Proc.
    def shareable_proc(&block)
      raise ArgumentError, "shareable_proc requires a block" unless block
      Ractor.shareable_proc(&block)
    end
  else
    def shareable_proc(&block) # :nodoc:
      raise ArgumentError, "shareable_proc requires a block" unless block
      block
    end
  end
end
