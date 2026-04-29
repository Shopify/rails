# frozen_string_literal: true

require "action_view/helpers/tags/placeholderable"

module ActionView
  module Helpers
    module Tags # :nodoc:
      class TextField < Base # :nodoc:
        include Placeholderable

        def render
          options = @options.stringify_keys
          options["size"] = options["maxlength"] unless options.key?("size")
          options["type"] ||= field_type
          options["value"] = options.fetch("value") { value_before_type_cast } unless field_type == "file"
          add_default_name_and_field(options)
          tag("input", options)
        end

        class << self
          attr_reader :field_type

          def inherited(subclass)
            super
            # Anonymous subclasses (Class.new(TextField)) have no name; skip the
            # hook so we don't NoMethodError on nil#split. Their #field_type
            # reader will return nil, matching pre-Ractor-safety behavior for
            # nameless classes.
            if subclass.name
              subclass.instance_variable_set(:@field_type, subclass.name.split("::").last.sub("Field", "").downcase.freeze)
            end
          end
        end

        @field_type = "text"

        private
          def field_type
            self.class.field_type
          end
      end
    end
  end
end
