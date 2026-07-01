# frozen_string_literal: true

# Entry point for the framework Ractor patches, required by
# Rails::Application#ractorize!. Each component's patch file registers
# before_freeze/on_freeze callbacks (and applies behavioral prepends); the
# constants they touch are resolved lazily inside those callbacks.

require "active_support/ractors"
require "active_support/ractors/patches"

require "active_record/ractor_patches" if defined?(ActiveRecord::Base)
require "action_dispatch/ractor_patches" if defined?(ActionDispatch)
require "action_view/ractor_patches" if defined?(ActionView) && defined?(ActionView::Base)
require "action_cable/ractor_patches" if defined?(ActionCable) && defined?(ActionCable::Server::Base)
