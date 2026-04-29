# frozen_string_literal: true

require "concurrent/map"
require "action_view/path_set"
require "action_view/render_parser"

module ActionView
  class DependencyTracker # :nodoc:
    extend ActiveSupport::Autoload

    autoload :ERBTracker
    autoload :RubyTracker
    autoload :WildcardResolver

    @trackers = Concurrent::Map.new

    def self.find_dependencies(name, template, view_paths = nil)
      tracker = @trackers[template.handler]
      return [] unless tracker

      tracker.call(name, template, view_paths)
    end

    def self.register_tracker(extension, tracker)
      handler = Template.handler_for_extension(extension)
      if tracker.respond_to?(:supports_view_paths?)
        @trackers[handler] = tracker
      else
        @trackers[handler] = lambda { |name, template, _|
          tracker.call(name, template)
        }
      end
    end

    def self.remove_tracker(handler)
      @trackers.delete(handler)
    end

    # Snapshots the +@trackers+ registry into a shareable frozen Hash so
    # +find_dependencies+ can read it from non-main Ractors during digest
    # dependency tracking. Called once from +Application#ractorize!+ after
    # +eager_load!+ has run all gem-level +register_tracker+ calls (jbuilder,
    # slim, haml, etc.). Subsequent +register_tracker+ / +remove_tracker+
    # calls would now raise +FrozenError+; in standard Rails apps those
    # calls only happen at file-load time, so this is safe.
    def self.make_shareable! # :nodoc:
      return if @trackers.frozen?
      @trackers = Ractor.make_shareable(@trackers.each_pair.to_h)
    end

    case ActionView.render_tracker
    when :ruby
      register_tracker :erb, RubyTracker
    else
      register_tracker :erb, ERBTracker
    end
  end
end
