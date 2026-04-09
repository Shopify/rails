# frozen_string_literal: true

class Object
  # Deeply freezes the object and its entire reachable object graph,
  # making it safe to share across Ractors.
  #
  #   config = { timeout: 30, retries: 3 }
  #   config.make_shareable!
  #   config.frozen? # => true
  #   Ractor.shareable?(config) # => true
  #
  # This is a convenience wrapper around +Ractor.make_shareable+. On Ruby
  # implementations without Ractor support it falls back to +freeze+.
  if defined?(Ractor)
    def make_shareable!
      Ractor.make_shareable(self)
    end
  else
    def make_shareable!
      freeze
    end
  end

  # Returns whether this object can be safely shared across Ractors.
  #
  #   "hello".freeze.shareable? # => true
  #   [].shareable?             # => false
  #
  # This is a convenience wrapper around +Ractor.shareable?+. On Ruby
  # implementations without Ractor support it falls back to +frozen?+.
  if defined?(Ractor)
    def shareable?
      Ractor.shareable?(self)
    end
  else
    def shareable?
      frozen?
    end
  end
end
