# frozen_string_literal: true

# :markup: markdown

module ActionDispatch
  # # Action Dispatch Reloader
  #
  # ActionDispatch::Reloader wraps the request with callbacks provided by
  # ActiveSupport::Reloader, intended to assist with code reloading during
  # development.
  #
  # ActionDispatch::Reloader is included in the middleware stack only if reloading
  # is enabled, which it is by the default in `development` mode.
  class Reloader < Executor
    def initialize(app, executor)
      @app = app
      @executor = executor
    end

    def call(env)
      view_reloader = Rails.application.reloaders.find { |reloader| reloader.is_a?(ActionView::CacheExpiry::ViewReloader) }
      view_reloader.build_watcher if view_reloader
      @app.call(env)
    end
  end
end
