# frozen_string_literal: true

# Shims for +Ractor+ shareability methods so framework code can call them
# unconditionally regardless of the Ruby version.
#
# When +Ractor+ is not defined, or the underlying method is not available, the
# shim is a no-op that simply returns its argument (or the given block).
# Otherwise the call is forwarded to the matching +Ractor+ class method.
#
#   ractor_make_shareable(obj)        # => Ractor.make_shareable(obj)        or obj
#   ractor_shareable?(obj)            # => Ractor.shareable?(obj)            or obj
#   ractor_shareable_proc   { ... }   # => Ractor.shareable_proc   { ... }   or the block
#   ractor_shareable_lambda { ... }   # => Ractor.shareable_lambda { ... }   or the block
module Kernel
  if defined?(Ractor) && Ractor.respond_to?(:make_shareable)
    def ractor_make_shareable(obj, copy: false)
      Ractor.make_shareable(obj, copy: copy)
    end
  else
    def ractor_make_shareable(obj, copy: false)
      obj
    end
  end

  if defined?(Ractor) && Ractor.respond_to?(:shareable?)
    def ractor_shareable?(obj)
      Ractor.shareable?(obj)
    end
  else
    def ractor_shareable?(obj)
      obj
    end
  end

  if defined?(Ractor) && Ractor.respond_to?(:shareable_proc)
    def ractor_shareable_proc(self: nil, &block)
      Ractor.shareable_proc(self: { self: }[:self], &block)
    end
  else
    def ractor_shareable_proc(self: nil, &block)
      block
    end
  end

  if defined?(Ractor) && Ractor.respond_to?(:shareable_lambda)
    def ractor_shareable_lambda(self: nil, &block)
      Ractor.shareable_lambda(self: { self: }[:self], &block)
    end
  else
    def ractor_shareable_lambda(&block)
      block
    end
  end

  private :ractor_make_shareable, :ractor_shareable?, :ractor_shareable_proc, :ractor_shareable_lambda
end
