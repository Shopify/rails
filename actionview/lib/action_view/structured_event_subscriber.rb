# frozen_string_literal: true

require "active_support/structured_event_subscriber"

module ActionView
  class StructuredEventSubscriber < ActiveSupport::StructuredEventSubscriber # :nodoc:
    VIEWS_PATTERN = /^app\/views\//

    def render_template(event)
      emit_debug_event("action_view.render_template",
        identifier: from_rails_root(event.payload[:identifier]),
        layout: from_rails_root(event.payload[:layout]),
        duration_ms: event.duration.round(2),
        gc_ms: event.gc_time.round(2),
      )
    end
    debug_only :render_template

    def render_partial(event)
      emit_debug_event("action_view.render_partial",
        identifier: from_rails_root(event.payload[:identifier]),
        layout: from_rails_root(event.payload[:layout]),
        duration_ms: event.duration.round(2),
        gc_ms: event.gc_time.round(2),
        cache_hit: event.payload[:cache_hit],
      )
    end
    debug_only :render_partial

    def render_layout(event)
      emit_event("action_view.render_layout",
        identifier: from_rails_root(event.payload[:identifier]),
        duration_ms: event.duration.round(2),
        gc_ms: event.gc_time.round(2),
      )
    end
    debug_only :render_layout

    def render_collection(event)
      emit_debug_event("action_view.render_collection",
        identifier: from_rails_root(event.payload[:identifier] || "templates"),
        layout: from_rails_root(event.payload[:layout]),
        duration_ms: event.duration.round(2),
        gc_ms: event.gc_time.round(2),
        cache_hits: event.payload[:cache_hits],
        count: event.payload[:count],
      )
    end
    debug_only :render_collection

    module Utils # :nodoc:
      class << self
        # Cache +Rails.root+ at the module level so per-instance method
        # calls don't try to memoize through an instance ivar. The Start
        # and StructuredEventSubscriber instances that include +Utils+ are
        # registered with +ActiveSupport::Notifications+ at boot and end
        # up deeply frozen by +Fanout#make_shareable!+, which makes any
        # +@root ||= ...+ on the instance raise +FrozenError+.
        #
        # +Rails.root+ is fixed at boot, so a single shared value is fine.
        # +StructuredEventSubscriber.make_shareable!+ warms this from the
        # main Ractor before the subscriber graph is deep-frozen.
        def rails_root
          @rails_root ||= Rails.try(:root)
        end
      end

      private
        def from_rails_root(string)
          return unless string

          if (root = Utils.rails_root)
            string = string.sub("#{root}/", "")
          end
          string.sub!(VIEWS_PATTERN, "")
          string
        end
    end

    include Utils

    # Warm the boot-time +Rails.root+ cache held on +Utils+ before the
    # subscriber graph is deep-frozen via +Fanout#make_shareable!+. The
    # +Start+ instances registered for +render_template.action_view+ /
    # +render_layout.action_view+ and the +StructuredEventSubscriber+
    # instance itself all read +Rails.root+ from inside the request
    # Ractor via +from_rails_root+. Caching it on +Utils+ at boot means
    # the runtime path only reads a frozen value.
    def self.make_shareable! # :nodoc:
      Utils.rails_root
      Utils.make_shareable!
      super
    end

    class Start # :nodoc:
      include Utils

      def start(name, id, payload)
        ActiveSupport.event_reporter.debug("action_view.render_start",
          filter_payload: false,
          is_layout: name == "render_layout.action_view",
          identifier: from_rails_root(payload[:identifier]),
          layout: from_rails_root(payload[:layout]),
        )
      end

      def finish(name, id, payload)
      end
    end

    def self.attach_to(*)
      ActiveSupport::Notifications.subscribe("render_template.action_view", Start.new)
      ActiveSupport::Notifications.subscribe("render_layout.action_view", Start.new)

      super
    end
  end
end

ActionView::StructuredEventSubscriber.attach_to :action_view
