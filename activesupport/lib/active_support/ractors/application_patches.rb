# frozen_string_literal: true

# Entry point for the framework Ractor patches, required by
# Rails::Application#ractorize!. Each component's patch file registers
# before_freeze/on_freeze callbacks (and applies behavioral prepends); the
# constants they touch are resolved lazily inside those callbacks.

require "active_support/ractors"
require "active_support/ractors/patches"

# Custom Rails config options live in Rails::Railtie::Configuration's @@options
# class variable; capture a shareable copy for non-main Ractors.
ActiveSupport::Ractors.on_freeze do
  Rails::Railtie::Configuration.capture_ractor_options! if defined?(Rails::Railtie::Configuration)
end

# Rails::Application#revision memoizes onto the application (read by the error
# reporter's context middleware); warm it before the app is frozen.
ActiveSupport::Ractors.before_freeze do
  Rails.application.revision if defined?(Rails) && Rails.application.respond_to?(:revision)
end

require "active_record/ractor_patches" if defined?(ActiveRecord::Base)
require "active_storage/ractor_patches" if defined?(ActiveStorage)
require "action_dispatch/ractor_patches" if defined?(ActionDispatch)
require "action_view/ractor_patches" if defined?(ActionView) && defined?(ActionView::Base)
require "action_cable/ractor_patches" if defined?(ActionCable) && defined?(ActionCable::Server::Base)

# Root pass: make every callback chain (controllers, models, the executor,
# ActionDispatch::Callbacks, CurrentAttributes, ...) Ractor-shareable in one go,
# via the registry in ActiveSupport::Callbacks. Registered last so it runs after
# all component warming (schema, reflections, class ivars) has completed and
# after unshareable_proc_action has been set to :raise.
ActiveSupport::Ractors.on_freeze do
  ActiveSupport::Callbacks.make_shareable
end
