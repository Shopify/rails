# frozen_string_literal: true

# :markup: markdown

module ActionText
  # Lightweight proxy for Nokogiri fragments in non-main Ractors.
  # Stores HTML as a string and dispatches Nokogiri operations to
  # the main Ractor where the C extension is available.
  class RactorHtmlProxy # :nodoc:
    attr_reader :html

    def initialize(html)
      @html = html.freeze
    end

    def to_html(options = {})
      h = @html
      o = options.empty? ? nil : Marshal.dump(options).freeze
      ::Ractor::Dispatch.main.run do
        opts = o ? Marshal.load(o) : {}
        ActionText::HtmlConversion.fragment_for_html(h).to_html(opts).freeze
      end
    end

    def to_s
      to_html
    end

    def css(selector)
      h = @html
      s = selector.freeze
      ::Ractor::Dispatch.main.run do
        ActionText::HtmlConversion.fragment_for_html(h).css(s)
      end
    end

    def elements
      h = @html
      ::Ractor::Dispatch.main.run do
        ActionText::HtmlConversion.fragment_for_html(h).elements
      end
    end
  end

  class Fragment
    class << self
      def wrap(fragment_or_html)
        case fragment_or_html
        when self
          fragment_or_html
        when Nokogiri::XML::DocumentFragment # base class for all fragments
          new(fragment_or_html)
        else
          from_html(fragment_or_html)
        end
      end

      def from_html(html)
        stripped = html.to_s.strip
        if !Ractor.main? && defined?(::Ractor::Dispatch)
          # Nokogiri C extension is not Ractor-safe. Store the raw
          # HTML and dispatch Nokogiri operations to the main Ractor
          # when needed.
          new(RactorHtmlProxy.new(stripped))
        else
          new(ActionText::HtmlConversion.fragment_for_html(stripped))
        end
      end
    end

    attr_reader :source

    delegate :deconstruct, to: "source.elements"

    def initialize(source)
      @source = source
    end

    def find_all(selector)
      source.css(selector)
    end

    def update
      yield source = self.source.dup
      self.class.new(source)
    end

    def replace(selector)
      update do |source|
        source.css(selector).each do |node|
          replacement_node = yield(node)
          node.replace(replacement_node.to_s) if node != replacement_node
        end
      end
    end

    def to_plain_text
      @plain_text ||= if source.is_a?(RactorHtmlProxy)
        h = source.html
        ::Ractor::Dispatch.main.run do
          node = ActionText::HtmlConversion.fragment_for_html(h)
          PlainTextConversion.node_to_plain_text(node).freeze
        end
      else
        PlainTextConversion.node_to_plain_text(source)
      end
    end

    def to_markdown
      @markdown ||= MarkdownConversion.node_to_markdown(source)
    end

    def to_html
      @html ||= HtmlConversion.node_to_html(source)
    end

    def to_s
      to_html
    end
  end
end
