# :markup: markdown
# frozen_string_literal: true

require "active_support/ractors"

module ActiveSupport
  module ClassAttribute # :nodoc:
    class << self
      def redefine(owner, name, owner_method, reader_method, value, instance_reader)
        ivar_name = :"@#{reader_method}"
        owner.instance_variable_set(ivar_name, value)

        owner_proc = ActiveSupport::Ractors.shareable_proc { owner }

        # If redefining on a singleton class, and including instance_reader, we
        # need to update it to use self.singleton_class instead of self.class
        if owner.singleton_class? && !owner.attached_object.is_a?(Module) && instance_reader
          owner.class_eval("def #{name}; self.singleton_class.#{reader_method}; end", __FILE__, __LINE__)
        end

        redefine_method(owner.singleton_class, owner_method, private: true, &owner_proc)
      end

      def redefine_method(owner, name, private: false, &block)
        owner.silence_redefinition_of_method(name)
        owner.define_method(name, &block)
        owner.send(:private, name) if private
      end
    end
  end
end
