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
  # Pre-computed +Regexp.union+ of +I18n::DEFAULT_INTERPOLATION_PATTERNS+,
  # frozen at load time so non-main Ractors can read it directly. The gem
  # caches this value lazily inside +I18n::INTERPOLATION_PATTERNS_CACHE+
  # (a +Hash.new { |h, p| h[p] = Regexp.union(p) }+), which is inherently
  # non-shareable due to its default proc and lazy mutation. Our override
  # of +interpolate_hash+ below uses this constant for the default-pattern
  # path so request Ractors never touch the gem's cache.
  #
  # The gem itself defines (and immediately deprecates) a similarly named
  # +I18n::INTERPOLATION_PATTERN+, so we use a distinct name to avoid the
  # deprecation warning and any aliasing surprises.
  RAILS_DEFAULT_INTERPOLATION_PATTERN = Regexp.union(I18n::DEFAULT_INTERPOLATION_PATTERNS).freeze

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

    # Override +I18n.interpolate_hash+ so request Ractors never read the
    # gem's +I18n::INTERPOLATION_PATTERNS_CACHE+, a
    # +Hash.new { |h, p| h[p] = Regexp.union(p) }+ that is structurally
    # non-shareable (mutable + default proc) regardless of +freeze+.
    #
    # The gem's implementation at +i18n/interpolate/ruby.rb:29-51+ does:
    #
    #   pattern = INTERPOLATION_PATTERNS_CACHE[config.interpolation_patterns]
    #   ... gsub(pattern) { |match| ... }
    #
    # That single +[]+ read raises +Ractor::IsolationError+ on non-main.
    # Our replacement avoids the cache entirely:
    #
    #   * If +config.interpolation_patterns+ equals (==) the gem's
    #     +DEFAULT_INTERPOLATION_PATTERNS+, use our pre-computed frozen
    #     +RAILS_DEFAULT_INTERPOLATION_PATTERN+ above. This is the hot
    #     path — every default-config app hits it on every translation.
    #   * Otherwise, recompute +Regexp.union(patterns)+ on the spot. This
    #     forfeits the gem's caching for non-default configurations, which
    #     are rare in practice and out of scope for this leaf.
    #
    # The +gsub+ body is copied verbatim from the gem
    # (+i18n/interpolate/ruby.rb:31-50+) so behavior is identical for
    # callers; only the pattern lookup differs. The same relocation rule
    # as +make_shareable!+ above applies — gem source is not patched.
    def interpolate_hash(string, values)
      patterns = config.interpolation_patterns
      pattern = if patterns == I18n::DEFAULT_INTERPOLATION_PATTERNS
        RAILS_DEFAULT_INTERPOLATION_PATTERN
      else
        Regexp.union(patterns)
      end

      interpolated = false

      interpolated_string = string.gsub(pattern) do |match|
        interpolated = true

        if match == "%%"
          "%"
        else
          key = ($1 || $2 || match.tr("%{}", "")).to_sym
          value = if values.key?(key)
            values[key]
          else
            config.missing_interpolation_argument_handler.call(key, values, string)
          end
          value = value.call(values) if value.respond_to?(:call)
          $3 ? sprintf("%#{$3}", value) : value
        end
      end

      interpolated ? interpolated_string : string
    end
  end
end
