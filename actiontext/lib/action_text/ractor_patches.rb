# frozen_string_literal: true

# ActionText Ractor patches, applied by Rails::Application#ractorize!.
#
# ActionText lazily memoizes its Nokogiri document classes in module instance
# variables the first time rich text is parsed. A non-main Ractor can neither
# set nor (for unshareable values) read those, so warm them on the main Ractor
# before freezing. The memoized values are Class objects, which are shareable.

require "active_support/ractors"

ActiveSupport::Ractors.before_freeze do
  if defined?(ActionText.html_document_class)
    ActionText.html_document_class
    ActionText.html_document_fragment_class
  end
rescue StandardError
  # Nokogiri may not be loaded in every configuration; ignore.
end
