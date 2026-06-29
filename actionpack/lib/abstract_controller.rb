# frozen_string_literal: true

# :markup: markdown

require "action_pack"
require "active_support"
require "active_support/rails"
require "active_support/i18n"
require "abstract_controller/deprecator"

module AbstractController
  extend ActiveSupport::Autoload

  autoload :ActionNotFound, "abstract_controller/base"
  autoload :Base
  autoload :Callbacks
  autoload :Collector
  autoload :DoubleRenderError, "abstract_controller/rendering"
  autoload :Helpers
  autoload :Logger
  autoload :Rendering
  autoload :Translation
  autoload :AssetPaths
  autoload :UrlFor

  eager_autoload do
    autoload :Caching
  end

  def self.eager_load!
    super
    AbstractController::Base.descendants.each do |controller|
      unless controller.abstract?
        controller.eager_load!
      end
    end
  end
end
