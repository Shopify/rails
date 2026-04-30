# frozen_string_literal: true

require "rails-html-sanitizer"

module ActionView
  module Helpers # :nodoc:
    # = Action View Sanitize \Helpers
    #
    # The SanitizeHelper module provides a set of methods for scrubbing text of undesired HTML elements.
    # These helper methods extend Action View making them callable within your template files.
    module SanitizeHelper
      mattr_accessor :sanitizer_vendor, default: Rails::HTML4::Sanitizer

      extend ActiveSupport::Concern

      # Sanitizes HTML input, stripping all but known-safe tags and attributes.
      #
      # It also strips +href+ / +src+ attributes with unsafe protocols like +javascript:+, while
      # also protecting against attempts to use Unicode, ASCII, and hex character references to work
      # around these protocol filters.
      #
      # The default sanitizer is +Rails::HTML5::SafeListSanitizer+. See {Rails HTML
      # Sanitizers}[https://github.com/rails/rails-html-sanitizer] for more information.
      #
      # Custom sanitization rules can also be provided.
      #
      # <b>Warning</b>: Adding disallowed tags or attributes to the allowlists may introduce
      # vulnerabilities into your application. Please rely on the default allowlists whenever
      # possible, because they are curated to maintain security and safety. If you think that the
      # default allowlists should be expanded, please {open an issue on the rails-html-sanitizer
      # project}[https://github.com/rails/rails-html-sanitizer/issues].
      #
      # Please note that sanitizing user-provided text does not guarantee that the
      # resulting markup is valid or even well-formed.
      #
      # ==== Options
      #
      # [+:tags+]
      #   An array of allowed tags.
      #
      # [+:attributes+]
      #   An array of allowed attributes.
      #
      # [+:scrubber+]
      #   A {Rails::HTML scrubber}[https://github.com/rails/rails-html-sanitizer]
      #   or {Loofah::Scrubber}[https://github.com/flavorjones/loofah] object that
      #   defines custom sanitization rules. A custom scrubber takes precedence over
      #   custom tags and attributes.
      #
      # ==== Examples
      #
      # ===== Normal use
      #
      #   <%= sanitize @comment.body %>
      #
      # ===== Providing custom lists of permitted tags and attributes
      #
      #   <%= sanitize @comment.body, tags: %w(strong em a), attributes: %w(href) %>
      #
      # ===== Providing a custom +Rails::HTML+ scrubber
      #
      #   class CommentScrubber < Rails::HTML::PermitScrubber
      #     def initialize
      #       super
      #       self.tags = %w( form script comment blockquote )
      #       self.attributes = %w( style )
      #     end
      #
      #     def skip_node?(node)
      #       node.text?
      #     end
      #   end
      #
      # <code></code>
      #
      #   <%= sanitize @comment.body, scrubber: CommentScrubber.new %>
      #
      # See {Rails HTML Sanitizer}[https://github.com/rails/rails-html-sanitizer] for
      # documentation about +Rails::HTML+ scrubbers.
      #
      # ===== Providing a custom +Loofah::Scrubber+
      #
      #   scrubber = Loofah::Scrubber.new do |node|
      #     node.remove if node.name == 'script'
      #   end
      #
      # <code></code>
      #
      #   <%= sanitize @comment.body, scrubber: scrubber %>
      #
      # See {Loofah's documentation}[https://github.com/flavorjones/loofah] for more
      # information about defining custom +Loofah::Scrubber+ objects.
      #
      # ==== Global Configuration
      #
      # To set the default allowed tags or attributes across your application:
      #
      #   # In config/application.rb
      #   config.action_view.sanitized_allowed_tags = ['strong', 'em', 'a']
      #   config.action_view.sanitized_allowed_attributes = ['href', 'title']
      #
      # The default, starting in \Rails 7.1, is to use an HTML5 parser for sanitization (if it is
      # available, see NOTE below). If you wish to revert back to the previous HTML4 behavior, you
      # can do so by setting the following in your application configuration:
      #
      #   # In config/application.rb
      #   config.action_view.sanitizer_vendor = Rails::HTML4::Sanitizer
      #
      # Or, if you're upgrading from a previous version of \Rails and wish to opt into the HTML5
      # behavior:
      #
      #   # In config/application.rb
      #   config.action_view.sanitizer_vendor = Rails::HTML5::Sanitizer
      #
      # NOTE: +Rails::HTML5::Sanitizer+ is not supported on JRuby, so on JRuby platforms \Rails will
      # fall back to using +Rails::HTML4::Sanitizer+.
      def sanitize(html, options = {})
        if Ractor.main?
          self.class.safe_list_sanitizer.sanitize(html, options)&.html_safe
        else
          SanitizeHelper._dispatch_sanitize(:safe_list_sanitizer, :sanitize, html, options)&.html_safe
        end
      end

      # Sanitizes a block of CSS code. Used by #sanitize when it comes across a style attribute.
      def sanitize_css(style)
        if Ractor.main?
          self.class.safe_list_sanitizer.sanitize_css(style)
        else
          SanitizeHelper._dispatch_sanitize(:safe_list_sanitizer, :sanitize_css, style)
        end
      end

      # Strips all HTML tags from +html+, including comments and special characters.
      #
      #   strip_tags("Strip <i>these</i> tags!")
      #   # => Strip these tags!
      #
      #   strip_tags("<b>Bold</b> no more!  <a href='more.html'>See more here</a>...")
      #   # => Bold no more!  See more here...
      #
      #   strip_tags("<div id='top-bar'>Welcome to my website!</div>")
      #   # => Welcome to my website!
      #
      #   strip_tags("> A quote from Smith & Wesson")
      #   # => &gt; A quote from Smith &amp; Wesson
      def strip_tags(html)
        if Ractor.main?
          self.class.full_sanitizer.sanitize(html)&.html_safe
        else
          SanitizeHelper._dispatch_sanitize(:full_sanitizer, :sanitize, html)&.html_safe
        end
      end

      # Strips all link tags from +html+ leaving just the link text.
      #
      #   strip_links('<a href="http://www.rubyonrails.org">Ruby on Rails</a>')
      #   # => Ruby on Rails
      #
      #   strip_links('Please e-mail me at <a href="mailto:me@email.com">me@email.com</a>.')
      #   # => Please e-mail me at me@email.com.
      #
      #   strip_links('Blog: <a href="http://www.myblog.com/" class="nav" target=\"_blank\">Visit</a>.')
      #   # => Blog: Visit.
      #
      #   strip_links('<<a href="https://example.org">malformed & link</a>')
      #   # => &lt;malformed &amp; link
      def strip_links(html)
        if Ractor.main?
          self.class.link_sanitizer.sanitize(html)
        else
          SanitizeHelper._dispatch_sanitize(:link_sanitizer, :sanitize, html)
        end
      end

      # Dispatch helper for sanitize calls from non-main Ractors. The actual
      # sanitize work happens inside the +rails-html-sanitizer+ gem, which
      # calls into Loofah and Nokogiri. Nokogiri's C extension is
      # +Ractor::UnsafeError+-marked, and Loofah lazily writes
      # +@document_klass+ on +DocumentFragment+ classes — neither is fixable
      # without patching gem code.
      #
      # The sanitizer instances themselves can't be cached as shareable
      # because they hold a +Rails::HTML::PermitScrubber+ that mutates per
      # call (e.g. assigning +@tags+ / +@attributes+ from options). So we
      # build a fresh sanitizer on the main side and run the sanitize call
      # there. The +sanitizer_kind+ symbol selects which factory method on
      # +sanitizer_vendor+ to use (+:full_sanitizer+, +:link_sanitizer+, or
      # +:safe_list_sanitizer+).
      def self._dispatch_sanitize(sanitizer_kind, method, *args)
        # Deep-freeze the entire args array so that capturing it inside the
        # +shareable_proc+ used by +Ractor::Dispatch::Executor#submit+
        # passes the shareability check on captured locals.
        shareable_args = Ractor.make_shareable(args, copy: true)
        Ractor::Dispatch.main.run do
          ActionView::Helpers::SanitizeHelper
            .sanitizer_vendor
            .public_send(sanitizer_kind)
            .new
            .public_send(method, *shareable_args)
        end
      end

      # +make_default_sanitizers_shareable!+ runs during
      # +Rails::Application#ractorize!+. Its job is to make the *first*
      # sanitize call from a non-main Ractor not crash on lazy state in
      # the underlying +rails-html-sanitizer+ / Loofah / Nokogiri stack.
      #
      # We deliberately do NOT cache shareable sanitizer instances at the
      # module level: +Rails::HTML::SafeListSanitizer+ holds a
      # +Rails::HTML::PermitScrubber+ that mutates per call (assigning
      # +@tags+ / +@attributes+ / +@prune+ from options on every call),
      # and deep-freezing it would raise +FrozenError+ inside +sanitize+.
      # Instead, the non-main Ractor path goes through
      # +_dispatch_sanitize+, which runs the call on the main Ractor with
      # a fresh sanitizer instance. The warmup here just touches enough
      # of the gem stack that no lazy class-level ivar writes fire on the
      # request path.
      def self.make_default_sanitizers_shareable!
        # Eagerly populate Loofah's lazy +@document_klass+ ivar on the
        # +DocumentFragment+ classes that +rails-html-sanitizer+ dispatches
        # through. Without this, the first sanitize call hits
        # +Loofah::HtmlFragmentBehavior::ClassMethods#document_klass+,
        # which does +@document_klass ||= ...+ on the Loofah class and
        # raises +Ractor::IsolationError+ when called from a non-main
        # Ractor. We can't patch the Loofah gem, so trigger the lazy
        # write here from the main Ractor.
        if defined?(Loofah::HTML5::DocumentFragment) && Loofah.respond_to?(:html5_support?) && Loofah.html5_support?
          Loofah::HTML5::DocumentFragment.document_klass
        end
        if defined?(Loofah::HTML4::DocumentFragment)
          Loofah::HTML4::DocumentFragment.document_klass
        end
        nil
      end

      module ClassMethods # :nodoc:
        attr_writer :full_sanitizer, :link_sanitizer, :safe_list_sanitizer

        def sanitizer_vendor
          ActionView::Helpers::SanitizeHelper.sanitizer_vendor
        end

        def sanitized_allowed_tags
          sanitizer_vendor.safe_list_sanitizer.allowed_tags
        end

        def sanitized_allowed_attributes
          sanitizer_vendor.safe_list_sanitizer.allowed_attributes
        end

        # Gets the Rails::HTML::FullSanitizer instance used by +strip_tags+. Replace with
        # any object that responds to +sanitize+.
        #
        #   class Application < Rails::Application
        #     config.action_view.full_sanitizer = MySpecialSanitizer.new
        #   end
        # Note: these readers are only invoked from the main Ractor.
        # +SanitizeHelper#sanitize+ / +#strip_tags+ / +#strip_links+ /
        # +#sanitize_css+ check +Ractor.main?+ and route non-main calls
        # through +SanitizeHelper._dispatch_sanitize+ (which runs the
        # actual sanitize on the main Ractor with a fresh sanitizer
        # instance). So the lazy +||=+ write here is safe.
        def full_sanitizer
          @full_sanitizer ||= sanitizer_vendor.full_sanitizer.new
        end

        # Gets the Rails::HTML::LinkSanitizer instance used by +strip_links+.
        # Replace with any object that responds to +sanitize+.
        #
        #   class Application < Rails::Application
        #     config.action_view.link_sanitizer = MySpecialSanitizer.new
        #   end
        def link_sanitizer
          @link_sanitizer ||= sanitizer_vendor.link_sanitizer.new
        end

        # Gets the Rails::HTML::SafeListSanitizer instance used by sanitize and +sanitize_css+.
        # Replace with any object that responds to +sanitize+.
        #
        #   class Application < Rails::Application
        #     config.action_view.safe_list_sanitizer = MySpecialSanitizer.new
        #   end
        def safe_list_sanitizer
          @safe_list_sanitizer ||= sanitizer_vendor.safe_list_sanitizer.new
        end
      end
    end
  end
end
