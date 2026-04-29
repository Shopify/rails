# frozen_string_literal: true

require "active_support/core_ext/hash/deep_merge"
require "active_support/core_ext/hash/except"
require "active_support/core_ext/hash/slice"
begin
  require "i18n"
  require "i18n/backend/fallbacks"
rescue LoadError => e
  warn "The i18n gem is not available. Please add it to your Gemfile and run bundle install"
  raise e
end
require "active_support/lazy_load_hooks"

ActiveSupport.run_load_hooks(:i18n)
I18n.load_path << File.expand_path("locale/en.yml", __dir__)
I18n.load_path << File.expand_path("locale/en.rb", __dir__)

# Ractor-safe Rails additions — extend the I18n module with the
# class methods Rails needs for ractorize!. Defining these in the
# i18n gem itself is incorrect because gem patches do not survive
# bundle install.
module I18n
  class << self
    # Force-build the lazy +@@fallbacks+ class variable and deep-freeze
    # the value so it can be read from non-main Ractors. The reader
    # +I18n.fallbacks+ is called from every per-request
    # +ActionView::LookupContext#initialize_details+ via the
    # +Accessors::DEFAULT_PROCS[:locale]+ proc, so the cvar value must
    # be shareable.
    #
    # +I18n::Locale::Fallbacks+ is a +Hash+ subclass that lazily caches
    # +compute(locale)+ results via +super || store(...)+ in +#[]+.
    # Warm that cache for the default locale and any registered
    # available locales before freezing, so request-path lookups hit
    # the cache instead of mutating a frozen Hash.
    #
    # Idempotent; safe to call repeatedly.
    def make_shareable!
      @@fallbacks ||= I18n::Locale::Fallbacks.new
      return self if Ractor.shareable?(@@fallbacks)

      locales = []
      locales << default_locale if respond_to?(:default_locale)
      locales << locale if respond_to?(:locale)
      if respond_to?(:available_locales) && available_locales_initialized?
        locales.concat(available_locales)
      end
      locales.compact.uniq.each { |loc| @@fallbacks[loc] }

      Ractor.make_shareable(@@fallbacks)
      self
    end

    def available_locales_initialized?
      config.available_locales_initialized?
    end
  end
end
