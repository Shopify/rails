# frozen_string_literal: true

require "active_support"
require "active_support/rails"

require "action_text/version"
require "action_text/deprecator"

require "nokogiri"
begin
  require "nokogiri/html5"
rescue LoadError
  # Nokogiri::HTML5 is unavailable; fall back to HTML4.
end

# :markup: markdown
# :include: ../README.md
module ActionText
  extend ActiveSupport::Autoload

  autoload :Attachable
  autoload :AttachmentGallery
  autoload :Attachment
  autoload :Attribute
  autoload :BottomUpReducer
  autoload :Configurator
  autoload :Content
  autoload :Editor
  autoload :Encryption
  autoload :Fragment
  autoload :FixtureSet
  autoload :HtmlConversion
  autoload :MarkdownConversion
  autoload :PlainTextConversion
  autoload :Registry
  autoload :Rendering
  autoload :Serialization
  autoload :TrixAttachment

  module Attachables
    extend ActiveSupport::Autoload

    autoload :ContentAttachment
    autoload :MissingAttachable
    autoload :RemoteImage
  end

  module Attachments
    extend ActiveSupport::Autoload

    autoload :Caching
    autoload :Conversion
    autoload :Minification
    autoload :TrixConversion
  end

  class << self
    attr_reader :html_document_class, :html_document_fragment_class
  end

  @html_document_class =
    defined?(Nokogiri::HTML5) ? Nokogiri::HTML5::Document : Nokogiri::HTML4::Document
  @html_document_fragment_class =
    defined?(Nokogiri::HTML5) ? Nokogiri::HTML5::DocumentFragment : Nokogiri::HTML4::DocumentFragment
end
