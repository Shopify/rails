# frozen_string_literal: true

require "active_support/core_ext/module/delegation"
require "active_support/logger"

module ActiveSupport
  # A Ractor-shareable +ActiveSupport::Logger+.
  #
  # +flush+ honors the Rails per-request contract: Rails::Rack::Logger calls ActiveSupport::LogSubscriber.flush_all!,
  # which calls +#flush+ on the logger to drain a request's logs before the next request is processed.
  class ShareableLogger < ActiveSupport::Logger
    def initialize(*args, level: ::Logger::DEBUG, progname: nil, formatter: nil, datetime_format: nil, **logdev_options)
      # super(nil, ...) sets level/formatter/progname without building a Logger::LogDevice; the device and rotation
      # args go to the Writer's real device instead.
      super(nil, level: level, progname: progname, formatter: formatter, datetime_format: datetime_format)
      @logdev = DeviceProxy.new(*args, **logdev_options)
    end

    delegate :flush, to: :@logdev
  end
end

require "active_support/shareable_logger/device_proxy"
