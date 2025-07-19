# frozen_string_literal: true

begin
  gem "msgpack", ">= 1.7.0"
  require "msgpack"
rescue LoadError => error
  warn "ActiveSupport::EventReporter::MessagePackEncoder requires the msgpack gem, version 1.7.0 or later. " \
    "Please add it to your Gemfile: `gem \"msgpack\", \">= 1.7.0\"`"
  raise error
end

module ActiveSupport
  class EventReporter
    # EventReporter encoder for serializing events to MessagePack format.
    module MessagePackEncoder
      class << self
        def encode(event)
          unless event[:payload].is_a?(Hash)
            event[:payload] = parameter_filter.filter(event[:payload].to_h)
          end

          event[:tags] = event[:tags].transform_values do |value|
            value.respond_to?(:to_h) ? value.to_h : value
          end
          ::MessagePack.pack(event)
        end

        def parameter_filter # :nodoc:
          @parameter_filter ||= ActiveSupport::ParameterFilter.new(
            ActiveSupport.filter_parameters, mask: ActiveSupport::ParameterFilter::FILTERED)
        end
      end
    end
  end
end
