# frozen_string_literal: true

require "active_support/core_ext/module/delegation"
require "active_support/logger"
require "active_support/logging/device_proxy"

module ActiveSupport
  module Logging # :nodoc:
    # A Ractor-shareable +ActiveSupport::Logger+ whose only departure from the stock logger is its sink: +@logdev+ is a
    # DeviceProxy that forwards lines to an Actor instead of owning a writable IO and a mutex (the parts of
    # +Logger::LogDevice+ that cannot be made shareable). Severity, level, formatter, +silence+, +log_at+, progname,
    # +<<+, +add+ and +close+ are all inherited (+::Logger#close+ already forwards to +@logdev+); only +flush+ and
    # +drain!+ are delegated to the proxy.
    #
    # +flush+ honors the Rails per-request contract: Rails::Rack::Logger calls ActiveSupport::LogSubscriber.flush_all!,
    # which calls +#flush+ on the logger to drain a request's logs before the next request is processed.
    class Logger < ActiveSupport::Logger
      delegate :flush, :drain!, to: :@logdev

      def initialize(*args, level: ::Logger::DEBUG, progname: nil, formatter: nil, datetime_format: nil, **logdev_options)
        # super(nil, ...) sets level/formatter/progname without building a Logger::LogDevice; the device and rotation
        # args go to the Actor's real device instead.
        super(nil, level: level, progname: progname, formatter: formatter, datetime_format: datetime_format)
        @logdev = DeviceProxy.new(*args, **logdev_options)
      end
    end
  end
end
