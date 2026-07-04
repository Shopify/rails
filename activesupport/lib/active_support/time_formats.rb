# frozen_string_literal: true

module ActiveSupport
  module TimeFormats
    # Deeply shareable so the class instance variable can be read from
    # non-main Ractors: TimeFormats.lookup reads @list during e.g.
    # Time#to_fs, which runs inside request-serving Ractors. The values
    # include lambdas, so a shallow .freeze is not enough.
    @list = ActiveSupport::Ractors.make_shareable({
      db: "%Y-%m-%d %H:%M:%S",
      inspect: "%Y-%m-%d %H:%M:%S.%9N %z",
      number: "%Y%m%d%H%M%S",
      nsec: "%Y%m%d%H%M%S%9N",
      usec: "%Y%m%d%H%M%S%6N",
      time: "%H:%M",
      short: "%d %b %H:%M",
      long: "%B %d, %Y %H:%M",
      long_ordinal: ActiveSupport::Ractors.shareable_lambda { |time|
        day_format = ActiveSupport::Inflector.ordinalize(time.day)
        time.strftime("%B #{day_format}, %Y %H:%M")
      },
      rfc822: ActiveSupport::Ractors.shareable_lambda { |time|
        offset_format = time.formatted_offset(false)
        time.strftime("%a, %d %b %Y %H:%M:%S #{offset_format}")
      },
      rfc2822: ActiveSupport::Ractors.shareable_lambda { |time| time.rfc2822 },
      iso8601: ActiveSupport::Ractors.shareable_lambda { |time| time.iso8601 }
    }.freeze

    singleton_class.attr_reader :list # :nodoc:

    DEPRECATED_LIST = ActiveSupport::Ractors.make_shareable(@list.dup) # :nodoc:

    def self.lookup(format) # :nodoc:
      @list[format] || DEPRECATED_LIST[format]
    end

    # Registers a new date format for formatting Time instances.
    # See +Time::DATE_FORMATS+ for built-in formats.
    # Use the format name as the name and either a strftime string or
    # Proc instance that takes a date argument as the value.
    def self.register(name, format)
      @list = ActiveSupport::Ractors.make_shareable(@list.merge(name => format).freeze)
    end
  end
end
