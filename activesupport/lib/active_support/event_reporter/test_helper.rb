# frozen_string_literal: true

module ActiveSupport::EventReporter::TestHelper # :nodoc:
  class EventSubscriber
    attr_reader :events

    def initialize
      @events = []
    end

    def emit(event)
      @events << event
    end
  end

  def event_matcher(name:, payload: nil, tags: {}, context: {}, source_location: nil)
    ->(event) {
      return false unless event[:name] == name
      return false unless event[:payload] == payload
      return false unless event[:tags] == tags
      return false unless event[:context] == context
      return false unless event[:source_location] == source_location if source_location

      true
    }
  end
end
