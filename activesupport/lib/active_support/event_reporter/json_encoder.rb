# frozen_string_literal: true

require "json"

module ActiveSupport
  class EventReporter
    # JSON encoder for serializing events to JSON format.
    #
    #   event = { name: "user_created", payload: { id: 123 }, tags: { api: true } }
    #   ActiveSupport::EventReporter::JSONEncoder.encode(event)
    #   # => {
    #   #      "name": "user_created",
    #   #      "payload": {
    #   #        "id": 123
    #   #      },
    #   #      "tags": {
    #   #        "api": true
    #   #      },
    #   #      "context": {}
    #   #    }
    #
    # Schematized events and tags MUST respond to #to_h to be serialized.
    #
    #   event = { name: "UserCreatedEvent", payload: #<UserCreatedEvent:0x111>, tags: { "GraphqlTag": #<GraphqlTag:0x111> } }
    #   ActiveSupport::EventReporter::JSONEncoder.encode(event)
    #   # => {
    #   #      "name": "UserCreatedEvent",
    #   #      "payload": {
    #   #        "id": 123
    #   #      },
    #   #      "tags": {
    #   #        "GraphqlTag": {
    #   #          "operation_name": "user_created",
    #   #          "operation_type": "mutation"
    #   #        }
    #   #      },
    #   #      "context": {}
    #   #    }
    module JSONEncoder
      class << self
        def encode(event)
          unless event[:payload].is_a?(Hash)
            event[:payload] = parameter_filter.filter(event[:payload].to_h)
          end

          event[:tags] = event[:tags].transform_values do |value|
            value.respond_to?(:to_h) ? value.to_h : value
          end
          ::JSON.generate(event)
        end

        def parameter_filter # :nodoc:
          @parameter_filter ||= ActiveSupport::ParameterFilter.new(
            ActiveSupport.filter_parameters, mask: ActiveSupport::ParameterFilter::FILTERED)
        end
      end
    end
  end
end
