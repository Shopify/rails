# frozen_string_literal: true

require "active_support/core_ext/string/output_safety"

module ActionView
  # Used as a buffer for views
  #
  # The main difference between this and ActiveSupport::SafeBuffer
  # is for the methods `<<` and `safe_expr_append=` the inputs are
  # checked for nil before they are assigned and `to_s` is called on
  # the input. For example:
  #
  #   obuf = ActionView::OutputBuffer.new "hello"
  #   obuf << 5
  #   puts obuf # => "hello5"
  #
  #   sbuf = ActiveSupport::SafeBuffer.new "hello"
  #   sbuf << 5
  #   puts sbuf # => "hello\u0005"
  #
  class OldOutputBuffer < ActiveSupport::SafeBuffer # :nodoc:
    def initialize(*)
      super
      encode!
    end

    def <<(value)
      return self if value.nil?
      super(value.to_s)
    end
    alias :append= :<<

    def safe_expr_append=(val)
      return self if val.nil?
      safe_concat val.to_s
    end

    alias :safe_append= :safe_concat

    def _unsafe_buffer
      self
    end
  end

  class FastOutputBuffer
    def initialize(buffer = "")
      @buffer = buffer.dup
      @buffer.encode!
    end

    delegate :length, :inspect, :blank?, :force_encoding, :empty?, :ascii_only?, :html_safe, to: :@buffer
    delegate_missing_to :@buffer # TODO: this is a shortcut

    def to_s
      @buffer.html_safe
    end

    def html_safe?
      true
    end

    def ==(other)
      @buffer == other
    end

    def eql?(other)
      @buffer.eql?(other)
    end

    def to_str
      @buffer.dup
    end

    def <<(value)
      unless value.nil?
        @buffer << if value.html_safe?
          value.to_s
        else
          CGI.escapeHTML(value.to_s)
        end
      end
      self
    end
    alias :append= :<<

    def safe_concat(value)
      @buffer << value
    end
    alias :safe_append= :safe_concat

    def safe_expr_append=(val)
      return self if val.nil?
      @buffer << val.to_s
    end

    def _unsafe_buffer
      @buffer
    end
  end

  OutputBuffer = FastOutputBuffer

  class StreamingBuffer # :nodoc:
    def initialize(block)
      @block = block
    end

    def <<(value)
      value = value.to_s
      value = ERB::Util.h(value) unless value.html_safe?
      @block.call(value)
    end
    alias :concat  :<<
    alias :append= :<<

    def safe_concat(value)
      @block.call(value.to_s)
    end
    alias :safe_append= :safe_concat

    def html_safe?
      true
    end

    def html_safe
      self
    end

    def _unsafe_buffer
      self
    end
  end
end
