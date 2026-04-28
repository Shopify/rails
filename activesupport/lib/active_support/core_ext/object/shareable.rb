# frozen_string_literal: true

class Object
  if defined?(Ractor)
    # Deeply freezes the object graph so it can be shared across Ractors,
    # then returns +self+. Wraps +Ractor.make_shareable(self)+.
    #
    # On Ruby implementations without Ractor support this falls back to
    # +freeze+.
    def make_shareable!
      Ractor.make_shareable(self)
      self
    end

    # Returns whether the object is shareable across Ractors. Wraps
    # +Ractor.shareable?(self)+.
    #
    # On Ruby implementations without Ractor support this falls back to
    # +frozen?+.
    def shareable?
      Ractor.shareable?(self)
    end
  else
    def make_shareable! # :nodoc:
      freeze
      self
    end

    def shareable? # :nodoc:
      frozen?
    end
  end
end
