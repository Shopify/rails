# frozen_string_literal: true

module ActiveSupport
  module ClassAttribute # :nodoc:
    class << self
      def redefine(owner, name, namespaced_name, value)
        ivar = :"@#{namespaced_name}"

        if owner.singleton_class?
          if owner.attached_object.is_a?(Module)
            owner.instance_variable_set(ivar, value)
            redefine_string_method(owner, namespaced_name, "instance_variable_get(:#{ivar})", private: true)
          else
            owner.instance_variable_set(ivar, value)
            redefine_string_method(owner, name, "instance_variable_get(:#{ivar})")
          end
        end

        # Store value as a class instance variable on the singleton class.
        # This avoids capturing it in a Proc closure, which would prevent
        # the method from being called in non-main Ractors.
        owner.singleton_class.instance_variable_set(ivar, value)

        redefine_string_method(owner.singleton_class, namespaced_name, <<~BODY, private: true)
          if singleton_class.instance_variable_defined?(:#{ivar})
            singleton_class.instance_variable_get(:#{ivar})
          else
            superclass.send(:#{namespaced_name})
          end
        BODY

        redefine_string_method(owner.singleton_class, "#{namespaced_name}=", <<~BODY, private: true, args: "value")
          singleton_class.instance_variable_set(:#{ivar}, value)
        BODY
      end

      private
        def redefine_string_method(owner, name, body, private: false, args: "")
          owner.silence_redefinition_of_method(name)
          owner.class_eval("def #{name}(#{args}); #{body}; end", __FILE__, __LINE__)
          owner.send(:private, name) if private
        end
    end
  end
end
