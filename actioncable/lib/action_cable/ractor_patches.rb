# frozen_string_literal: true

# Action Cable Ractor patches, applied by Rails::Application#ractorize!.
#
# ActionCable auto-mounts its server at /cable, so the route graph reaches the
# live server singleton and its configuration.

require "active_support/ractors"

module ActionCable
  module RactorPatches # :nodoc:
    # ActionCable::Configuration stores connection_class/health_check_application
    # as lambdas bound to the (unshareable) configuration. Replace with
    # self-detached shareable procs.
    module Configuration
      def freeze
        if connection_class && !Ractor.shareable?(connection_class)
          self.connection_class =
            Ractor.shareable_proc { "ApplicationCable::Connection".safe_constantize || ActionCable::Connection::Base }
        end
        if health_check_application && !Ractor.shareable?(health_check_application)
          self.health_check_application =
            Ractor.shareable_proc { |env| Rails::HealthController.action(:show).call(env) }
        end
        super
      end
    end

    # ActionCable::Server::Base holds a Monitor plus lazily-initialized handles
    # (all nil before a client connects); drop them on freeze. A frozen server
    # can't accept connections, which is fine for serving plain HTTP.
    module ServerBase
      def freeze
        @mutex = nil
        @remote_connections = @event_loop = @worker_pool = @executor = @pubsub = @heartbeat_timer = nil
        super
      end
    end
  end
end

ActiveSupport::Ractors.before_freeze do
  ActionCable::Configuration.prepend(ActionCable::RactorPatches::Configuration)
  ActionCable::Server::Base.prepend(ActionCable::RactorPatches::ServerBase)
end
