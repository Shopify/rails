# frozen_string_literal: true

module ActionView # :nodoc:
  class Template # :nodoc:
    # = Action View RawFile Template
    class RawFile # :nodoc:
      attr_accessor :type, :format

      def initialize(filename)
        @filename = filename.to_s
        extname = ::File.extname(filename).delete(".")
        @type = Template::Types[extname] || Template::Types[:text]
        @format = @type.symbol
      end

      def identifier
        @filename
      end

      def render(*args, &_)
        ::File.read(@filename)
      end
    end
  end
end
