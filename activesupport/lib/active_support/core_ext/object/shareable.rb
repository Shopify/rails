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

# Concurrent::Map explicitly undefs #freeze. Restore it so that
# Ractor.make_shareable can freeze instances. On freeze, convert the
# internal backend to a plain frozen Hash. After freeze, fetch falls
# back to read-only (no block execution for cache writes).
require "concurrent/map"
Concurrent::Map.define_method(:freeze) do
  @backend = each_pair.to_h.freeze
  @write_lock = nil
  super()
end

Concurrent::Map.prepend(Module.new do
  def fetch(key, *args, &block)
    if frozen?
      if @backend.key?(key)
        @backend[key]
      elsif block
        yield key
      elsif args.length > 0
        args[0]
      else
        raise KeyError, "key not found: #{key.inspect}"
      end
    else
      super
    end
  end

  def []=(key, value)
    if frozen?
      raise FrozenError, "can't modify frozen #{self.class}"
    else
      super
    end
  end

  def compute_if_absent(key, &block)
    if frozen?
      @backend.fetch(key) { yield }
    else
      super
    end
  end
end)
